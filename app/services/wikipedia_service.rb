require "net/http"
require "uri"
require "json"

class WikipediaService
  def initialize(intent_detector:)
    @intent_detector = intent_detector
  end

  def search(query)
    keywords    = KeywordExtractorService.extract(query)
    return nil if keywords.empty?

    query_words = TextNormalizerService.normalize(query)
    indicators  = @intent_detector.country_indicators.any? ? @intent_detector.country_indicators : %w[pays état nation puissance puissant]

    if query_words.any? { |qw| indicators.any? { |w| SimilarityCalculatorService.stem_match?(qw, w) } }
      result = search_country_related(query, query_words, keywords, indicators)
      return result if result
    end

    if query.match?(/\b(le|la|les)\s+(plus|moins)\b/i)
      list_keywords = ["liste"] + keywords
      Rails.logger.info "[WikipediaService] Superlatif : #{list_keywords.join(' ')}"
      extract = wiki_search("fr", list_keywords, query)
      if extract && relevant?(extract, query)
        return SearchResult.from_wikipedia(extract).to_s
      elsif extract
        Rails.logger.info "[WikipediaService] Superlatif non pertinent, passage standard"
      end
    end

    cast_words = @intent_detector.intent_words[:cast]
    if cast_words&.any? { |w| query_words.any? { |qw| SimilarityCalculatorService.stem_match?(qw, w) } }
      film_keywords = keywords + ["film"]
      Rails.logger.info "[WikipediaService] Cast+film : #{film_keywords.join(' ')}"
      extract = wiki_search("fr", film_keywords, query)
      return SearchResult.from_wikipedia(extract).to_s if extract
    end

    extract = wiki_search("fr", keywords, query)
    return nil if extract.nil?

    unless relevant?(extract, query)
      Rails.logger.info "[WikipediaService] Standard non pertinent, ignoré"
      return nil
    end

    SearchResult.from_wikipedia(extract).to_s
  rescue => e
    Rails.logger.error "[WikipediaService] Erreur search : #{e.message}"
    nil
  end

  def search_relaxed(query)
    keywords = KeywordExtractorService.extract(query)
    return nil if keywords.empty?

    extract = wiki_query("fr", keywords.join(" "), query, relaxed: true)
    extract ? SearchResult.from_wikipedia(extract).to_s : nil
  rescue => e
    Rails.logger.error "[WikipediaService] Erreur relaxé : #{e.message}"
    nil
  end

  def relevant?(extract, query)
    return true if query.nil? || query.empty?

    query_kw = KeywordExtractorService.extract(query)
    return true if query_kw.empty? || query_kw.size <= 1

    intro          = extract.split(/[.\n]/).first.to_s
    intro_norm     = TextNormalizerService.strip_accents(intro.downcase)
    matched        = query_kw.count { |kw| intro_norm.include?(TextNormalizerService.strip_accents(kw)) }
    min_needed     = [(query_kw.size * 2 / 3.0).ceil, 1].max
    matched >= min_needed
  end

  def wiki_search_individual(lang, keywords, original_query = "")
    keywords.sort_by { |w| -w.length }.each do |keyword|
      result = wiki_query(lang, keyword, original_query)
      return result if result
    end
    nil
  rescue => e
    Rails.logger.error "[WikipediaService] Erreur individuel #{lang} : #{e.message}"
    nil
  end

  def wiki_query(lang, search_text, original_query = "", relaxed: false)
    search_term = URI.encode_www_form_component(search_text)
    uri         = URI("https://#{lang}.wikipedia.org/w/api.php?action=query&list=search&srsearch=#{search_term}&srlimit=5&format=json")
    response    = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    data    = JSON.parse(response.body)
    results = data.dig("query", "search")

    if results.nil? || results.empty?
      suggestion = data.dig("query", "searchinfo", "suggestion")
      if suggestion
        Rails.logger.info "[WikipediaService] Suggestion : #{suggestion}"
        return wiki_query(lang, suggestion, original_query, relaxed: relaxed)
      end
      return nil
    end

    search_words     = TextNormalizerService.normalize(search_text)
    min_required     = [(search_words.size / 2.0).ceil, 1].max
    matching_results = []

    results.each_with_index do |r, idx|
      title_words   = TextNormalizerService.normalize(r["title"])
      snippet_text  = r["snippet"].to_s.gsub(/<[^>]*>/, "").gsub(/&#0*39;/, "'").gsub(/&amp;/, "&").gsub(/&quot;/, '"').downcase
      snippet_words = TextNormalizerService.normalize(snippet_text)

      title_match    = SimilarityCalculatorService.stem_match_count(search_words, title_words)
      unmatched      = search_words.reject { |sw| title_words.any? { |tw| SimilarityCalculatorService.stem_match?(sw, tw) } }
      snippet_bonus  = SimilarityCalculatorService.stem_match_count(unmatched, snippet_words)
      unique_matches = title_match + snippet_bonus
      weighted_score = title_match * 2 + snippet_bonus

      matching_results << { result: r, title_match: title_match, snippet_bonus: snippet_bonus, unique_matches: unique_matches, weighted_score: weighted_score, index: idx } if unique_matches >= min_required
    end

    matching_results.sort_by! { |m| [-m[:weighted_score], -m[:title_match], m[:index]] }

    matching_results.each do |m|
      page_title = m[:result]["title"]
      Rails.logger.info "[WikipediaService] Essai : #{page_title} (weighted=#{m[:weighted_score]}, titre=#{m[:title_match]}, snippet=#{m[:snippet_bonus]})"
      extract = wiki_extract(lang, page_title, original_query)
      return extract if extract
    end

    if relaxed
      results.each do |r|
        next if matching_results.any? { |m| m[:result]["title"] == r["title"] }
        title_words = TextNormalizerService.normalize(r["title"])
        snippet     = r["snippet"].to_s.gsub(/<[^>]*>/, "").downcase
        found_words = search_words.select { |w| title_words.include?(w) || snippet.include?(w) }
        if found_words.size >= min_required
          Rails.logger.info "[WikipediaService] Essai relaxé : #{r["title"]}"
          extract = wiki_extract(lang, r["title"], original_query)
          return extract if extract
        end
      end
    end

    Rails.logger.info "[WikipediaService] Aucun résultat pour '#{search_text}'"
    nil
  rescue => e
    Rails.logger.error "[WikipediaService] Erreur wiki_query : #{e.message}"
    nil
  end

  def wiki_extract(lang, page_title, original_query = "")
    encoded_title = URI.encode_www_form_component(page_title)
    uri           = URI("https://#{lang}.wikipedia.org/w/api.php?action=query&titles=#{encoded_title}&prop=extracts&explaintext=1&redirects=1&format=json")
    response      = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    pages     = JSON.parse(response.body).dig("query", "pages")
    full_text = pages&.values&.first&.dig("extract")
    return nil if full_text.nil? || full_text.strip.empty?

    if disambiguation_page?(full_text)
      Rails.logger.info "[WikipediaService] Page de désambiguïsation : #{page_title}"
      return follow_disambiguation(lang, page_title, original_query, full_text)
    end

    clean_text = full_text.gsub(/Sauf indication contraire[^.]*\./, "")
                          .gsub(/==\s*Voir aussi\s*==.*\z/m, "")
                          .gsub(/==\s*Notes et références\s*==.*\z/m, "")
                          .strip

    if clean_text.length < 300
      Rails.logger.info "[WikipediaService] Texte court (#{clean_text.length} chars), essai tableau HTML"
      table_text = wiki_extract_table(lang, page_title)
      if table_text
        intro_line = clean_text.split("\n").first.to_s.strip
        return "#{intro_line}\n#{table_text}" unless table_text.empty?
      end
    end

    best_section = @intent_detector.find_best_section(clean_text, original_query)

    if best_section.length > 2000
      best_section = best_section[0..1999]
      last_newline = best_section.rindex("\n")
      best_section = best_section[0..last_newline - 1] if last_newline && last_newline > 100
    end

    best_section.strip.empty? ? nil : best_section
  rescue => e
    Rails.logger.error "[WikipediaService] Erreur wiki_extract '#{page_title}' : #{e.message}"
    nil
  end

  def wiki_extract_table(lang, page_title)
    encoded  = URI.encode_www_form_component(page_title)
    uri      = URI("https://#{lang}.wikipedia.org/w/api.php?action=parse&page=#{encoded}&prop=text&redirects=1&format=json")
    response = Net::HTTP.get_response(uri)
    Rails.logger.info "[WikipediaService] wiki_extract_table HTTP #{response.code} pour '#{page_title}'"
    return nil unless response.code == "200"

    html = JSON.parse(response.body).dig("parse", "text", "*")
    return nil if html.nil?

    Rails.logger.info "[WikipediaService] wiki_extract_table HTML reçu (#{html.length} chars)"

    rows = []
    html.scan(/<tr[^>]*>(.*?)<\/tr>/m).each do |tr|
      cells = tr[0].scan(/<t[dh][^>]*>(.*?)<\/t[dh]>/m).map do |c|
        c[0].gsub(/<[^>]*>/, "")
            .gsub(/&nbsp;|&#160;/, " ").gsub(/&gt;/, ">").gsub(/&lt;/, "<")
            .gsub(/&amp;/, "&").gsub(/&#91;.*?&#93;/, "").gsub(/\[.*?\]/, "").strip
      end
      row = cells.reject(&:empty?)
      rows << row if row.size >= 2
    end

    Rails.logger.info "[WikipediaService] wiki_extract_table: #{rows.size} lignes"
    return nil if rows.empty?

    data_rows = rows[1..]
    return nil if data_rows.nil? || data_rows.empty?

    result = data_rows.first(15).map { |row| row.join(" — ") }.join("\n")
    Rails.logger.info "[WikipediaService] wiki_extract_table: #{result.length} chars"
    result
  rescue => e
    Rails.logger.error "[WikipediaService] Erreur tableau '#{page_title}' : #{e.class} #{e.message}"
    nil
  end

  def follow_disambiguation(lang, page_title, original_query, disambig_text)
    encoded  = URI.encode_www_form_component(page_title)
    uri      = URI("https://#{lang}.wikipedia.org/w/api.php?action=query&titles=#{encoded}&prop=links&pllimit=30&plnamespace=0&format=json")
    response = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    pages = JSON.parse(response.body).dig("query", "pages")
    return nil if pages.nil?

    links       = pages.values.first&.dig("links") || []
    link_titles = links.map { |l| l["title"] }.compact
    return nil if link_titles.empty?

    disambig_lines = disambig_text.split("\n").map(&:strip).reject(&:empty?)
    query_keywords = KeywordExtractorService.extract(original_query)
    page_words     = TextNormalizerService.normalize(page_title)
    discriminating = query_keywords.reject { |qw| page_words.any? { |pw| SimilarityCalculatorService.stem_match?(qw, pw) } }
    discriminating = query_keywords if discriminating.empty?

    scored = link_titles.map do |title|
      title_lower    = title.downcase
      title_words    = TextNormalizerService.normalize(title)
      matching_lines = disambig_lines.select { |line| line.downcase.include?(title_lower) || title_words.all? { |tw| line.downcase.include?(tw) } }
      desc_words     = matching_lines.flat_map { |line| TextNormalizerService.normalize(line) }.uniq

      desc_match   = discriminating.count { |qw| desc_words.any? { |dw| SimilarityCalculatorService.stem_match?(qw, dw) } }
      title_match  = discriminating.count { |qw| title_words.any? { |tw| SimilarityCalculatorService.stem_match?(qw, tw) } }
      year_penalty = title.match?(/\b(19|20)\d{2}\b/) ? 2 : 0
      list_penalty = title.downcase.start_with?("liste") ? 2 : 0
      score        = desc_match * 3 + title_match * 2 - year_penalty - list_penalty

      { title: title, score: score, desc_match: desc_match, title_match: title_match }
    end

    scored.sort_by! { |s| [-s[:score], -s[:desc_match]] }
    scored.select! { |s| s[:score] > 0 }

    Rails.logger.info "[WikipediaService] Désambiguïsation #{page_title} : #{scored.first(5).map { |s| "#{s[:title]}(#{s[:score]})" }.join(', ')}"

    scored.first(3).each do |s|
      Rails.logger.info "[WikipediaService] Essai désambiguïsation : #{s[:title]}"
      extract = wiki_extract(lang, s[:title], original_query)
      return extract if extract
    end

    nil
  rescue => e
    Rails.logger.error "[WikipediaService] Erreur follow_disambiguation : #{e.message}"
    nil
  end

  private

  def search_country_related(query, query_words, keywords, indicators)
    has_power_word = query_words.any? { |qw| %w[puissant puissants puissantes puissance puissances].any? { |w| SimilarityCalculatorService.stem_match?(qw, w) } }
    if has_power_word
      power_keywords = ["grande", "puissance", "pays"]
      Rails.logger.info "[WikipediaService] Grandes puissances : #{power_keywords.join(' ')}"
      extract = wiki_search("fr", power_keywords, query)
      return SearchResult.from_wikipedia(extract).to_s if extract
    end

    topic_only = keywords.reject { |k| indicators.any? { |w| SimilarityCalculatorService.stem_match?(k, w) } }
    if topic_only.any? && topic_only != keywords
      core_topic = topic_only.reject { |w| w.match?(/\A[a-zà-ÿ]+(ent|ons|ez|aient|ront|raient)\z/) }
      core_topic = topic_only if core_topic.empty?

      Rails.logger.info "[WikipediaService] Topic principal : #{core_topic.join(' ')}"
      extract = wiki_search("fr", core_topic, query)
      return SearchResult.from_wikipedia(extract).to_s if extract

      if core_topic != topic_only
        Rails.logger.info "[WikipediaService] Topic complet : #{topic_only.join(' ')}"
        extract = wiki_search("fr", topic_only, query)
        return SearchResult.from_wikipedia(extract).to_s if extract
      end
    end

    specific_keywords = ["liste"] + keywords
    Rails.logger.info "[WikipediaService] Spécifique pays : #{specific_keywords.join(' ')}"
    extract = wiki_search("fr", specific_keywords, query)
    SearchResult.from_wikipedia(extract).to_s if extract
  end

  def wiki_search(lang, keywords, original_query = "")
    wiki_query(lang, keywords.join(" "), original_query)
  rescue => e
    Rails.logger.error "[WikipediaService] Erreur wiki_search #{lang} : #{e.message}"
    nil
  end

  def disambiguation_page?(text)
    text.include?("peut faire référence") || text.include?("peut désigner") ||
      text.include?("Cette page d'homonymie") || text.include?("page d'homonymie") ||
      text.match?(/\A[^\n]{0,50}\s+peut\s+(faire référence|désigner|se référer)/)
  end
end
