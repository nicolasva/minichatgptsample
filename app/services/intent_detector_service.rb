require "yaml"
require "fileutils"

class IntentDetectorService
  KEYWORDS_PATH   = Rails.root.join("config", "intent_keywords.yml").to_s
  CACHE_PATH      = Rails.root.join("tmp", "intent_keywords_enriched.yml").to_s
  INTENT_PRIORITY = %i[cast treatment cause history synopsis country].freeze

  attr_reader :intent_words, :intent_targets, :country_indicators

  def initialize(wiktionary_service:)
    @wiktionary = wiktionary_service
    load_keywords
  end

  def detect(query_words)
    INTENT_PRIORITY.each do |intent|
      words = @intent_words[intent]
      next if words.nil? || words.empty?
      return intent if query_words.any? { |qw| words.any? { |w| SimilarityCalculatorService.stem_match?(qw, w) } }
    end
    nil
  end

  def find_best_section(full_text, query)
    return full_text.split(/\n\n+==/).first.to_s.strip if query.empty?

    sections = parse_sections(full_text)
    intro    = sections.first.to_s.strip
    return intro if sections.size <= 1

    query_words     = TextNormalizerService.normalize(query)
    intent          = detect(query_words)
    target_keywords = intent ? (@intent_targets[intent] || []) : []

    if target_keywords.any?
      # 1er passage : titres de section (== Titre ==)
      sections.each do |section|
        first_line = TextNormalizerService.strip_accents(section.split("\n").first.to_s.downcase)
        if target_keywords.any? { |kw| first_line.include?(TextNormalizerService.strip_accents(kw)) }
          content = section.split("\n").reject { |l| l.match?(/\A={2,3}\s/) }.join("\n").strip
          return content unless content.empty?
        end
      end

      # 2ème passage : sous-sections (=== Sous-titre ===)
      sections.each do |section|
        lines            = section.split("\n")
        combined_content = []
        lines.each_with_index do |line, idx|
          next unless line.match?(/\A===/)
          line_lower = TextNormalizerService.strip_accents(line.downcase)
          if target_keywords.any? { |kw| line_lower.include?(TextNormalizerService.strip_accents(kw)) }
            (idx + 1...lines.size).each do |j|
              break if lines[j].match?(/\A={2,3}\s/)
              combined_content << lines[j]
            end
          end
        end
        content = combined_content.join("\n").strip
        return content unless content.empty?
      end
    end

    intro
  end

  private

  def parse_sections(full_text)
    sections = []
    current  = ""
    full_text.split("\n").each do |line|
      if line.match?(/\A==\s[^=]/) && !current.empty?
        sections << current.strip
        current = ""
      end
      current += line + "\n"
    end
    sections << current.strip unless current.strip.empty?
    sections
  end

  def load_keywords
    if File.exist?(CACHE_PATH) && File.mtime(CACHE_PATH) > File.mtime(KEYWORDS_PATH)
      cached              = YAML.load_file(CACHE_PATH)
      @intent_words       = cached["intent_words"].transform_keys(&:to_sym)
      @intent_targets     = cached["intent_targets"].transform_keys(&:to_sym)
      @country_indicators = cached["country_indicators"]
      Rails.logger.info "[IntentDetectorService] Chargé depuis cache (#{@intent_words.values.map(&:size).sum} mots)"
      return
    end

    config  = YAML.load_file(KEYWORDS_PATH)
    intents = config["intents"]

    @intent_words   = {}
    @intent_targets = {}

    intents.each do |name, data|
      key        = name.to_sym
      base_words = (data["seeds"] || []) + (data["extra_words"] || [])
      enriched   = (data["seeds"] || []).flat_map do |seed|
        synonyms = @wiktionary.find_synonyms(seed)
        Rails.logger.info "[IntentDetectorService] '#{seed}' : +#{synonyms.size} synonymes" if synonyms.any?
        synonyms
      end

      @intent_words[key]   = (base_words + enriched).map(&:downcase).uniq
      @intent_targets[key] = (data["target_sections"] || []).map(&:downcase).uniq
    end

    @country_indicators = (config["country_indicators"] || []).map(&:downcase).uniq

    FileUtils.mkdir_p(File.dirname(CACHE_PATH))
    File.write(CACHE_PATH, {
      "intent_words"       => @intent_words.transform_keys(&:to_s),
      "intent_targets"     => @intent_targets.transform_keys(&:to_s),
      "country_indicators" => @country_indicators
    }.to_yaml)
    Rails.logger.info "[IntentDetectorService] Enrichi et mis en cache (#{@intent_words.values.map(&:size).sum} mots)"
  rescue => e
    Rails.logger.error "[IntentDetectorService] Erreur chargement : #{e.message}"
    @intent_words       = {}
    @intent_targets     = {}
    @country_indicators = []
  end
end
