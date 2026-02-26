class WebSearchOrchestratorService
  def initialize(wiktionary:, wikipedia:, duckduckgo:, tavily:, compound_resolver:)
    @wiktionary        = wiktionary
    @wikipedia         = wikipedia
    @duckduckgo        = duckduckgo
    @tavily            = tavily
    @compound_resolver = compound_resolver
  end

  def search(query)
    enriched_query = @compound_resolver.resolve(query)
    if enriched_query != query.downcase
      Rails.logger.info "[WebSearchOrchestratorService] Expressions composées : '#{query}' → '#{enriched_query}'"
    end

    result = search_direct(enriched_query) if enriched_query != query.downcase
    return result if result

    result = search_direct(query)
    return result if result

    keywords = KeywordExtractorService.extract(enriched_query)
    return nil if keywords.empty?

    Rails.logger.info "[WebSearchOrchestratorService] Recherche directe échouée, essai synonymes..."
    result = search_with_synonyms(enriched_query, keywords)
    return result if result && @wikipedia.relevant?(result, query)

    Rails.logger.info "[WebSearchOrchestratorService] Synonymes échoués, essai définitions Wikipedia..."
    result = search_with_definitions(enriched_query, keywords)
    return result if result && @wikipedia.relevant?(result, query)

    Rails.logger.info "[WebSearchOrchestratorService] Définitions échouées, essai correction orthographique..."
    result = search_with_spelling_correction(enriched_query, keywords)
    return result if result && @wikipedia.relevant?(result, query)

    Rails.logger.info "[WebSearchOrchestratorService] Correction échouée, essai Wikipedia individuel..."
    extract = @wikipedia.wiki_search_individual("fr", keywords, enriched_query)
    if extract
      full_result = "D'après Wikipedia : #{extract}"
      return full_result if @wikipedia.relevant?(full_result, query)
    end

    nil
  rescue => e
    Rails.logger.error "[WebSearchOrchestratorService] Erreur : #{e.message}"
    nil
  end

  private

  def search_direct(query)
    @tavily.search(query) || @duckduckgo.search_api(query) || @wikipedia.search(query) || @duckduckgo.search_web(query)
  rescue => e
    Rails.logger.error "[WebSearchOrchestratorService] Erreur directe : #{e.message}"
    nil
  end

  def search_relaxed(query)
    @tavily.search(query) || @duckduckgo.search_api(query) || @wikipedia.search_relaxed(query) || @duckduckgo.search_web(query)
  rescue => e
    Rails.logger.error "[WebSearchOrchestratorService] Erreur relaxée : #{e.message}"
    nil
  end

  def search_with_synonyms(query, keywords)
    keywords.each do |word|
      synonyms = @wiktionary.find_synonyms(word)
      next if synonyms.empty?
      Rails.logger.info "[WebSearchOrchestratorService] Synonymes de '#{word}' : #{synonyms.join(', ')}"

      synonyms.each do |syn|
        new_query = query.gsub(/#{Regexp.escape(word)}/i, syn)
        result    = search_relaxed(new_query)
        return result if result
      end
    end
    nil
  rescue => e
    Rails.logger.error "[WebSearchOrchestratorService] Erreur synonymes : #{e.message}"
    nil
  end

  def search_with_definitions(query, keywords)
    keywords.sort_by { |w| -w.length }.each do |word|
      definition = @wiktionary.definition(word)
      next if definition.nil?
      Rails.logger.info "[WebSearchOrchestratorService] Définition de '#{word}' : #{definition[0..80]}..."

      definition_keywords = KeywordExtractorService.extract(definition).first(2)
      next if definition_keywords.empty?

      other_keywords = keywords.reject { |k| k == word }
      (other_keywords + [definition_keywords.first]).join(" ").tap do |nq|
        Rails.logger.info "[WebSearchOrchestratorService] Recherche enrichie : '#{nq}'"
        result = search_relaxed(nq)
        return result if result
      end

      if definition_keywords.size > 1
        nq = (other_keywords + [definition_keywords.last]).join(" ")
        result = search_relaxed(nq)
        return result if result
      end
    end
    nil
  rescue => e
    Rails.logger.error "[WebSearchOrchestratorService] Erreur définitions : #{e.message}"
    nil
  end

  def search_with_spelling_correction(query, keywords)
    corrected_keywords = keywords.map { |w| @wiktionary.correct_spelling(w) || w }
    return nil if corrected_keywords == keywords

    corrected_query = corrected_keywords.join(" ")
    Rails.logger.info "[WebSearchOrchestratorService] Correction : #{keywords.join(' ')} → #{corrected_query}"
    search_direct(corrected_query)
  rescue => e
    Rails.logger.error "[WebSearchOrchestratorService] Erreur correction : #{e.message}"
    nil
  end
end
