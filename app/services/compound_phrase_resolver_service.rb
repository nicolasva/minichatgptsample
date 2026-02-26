require "yaml"
require "fileutils"

class CompoundPhraseResolverService
  CACHE_PATH = Rails.root.join("tmp", "compound_phrases_cache.yml").to_s

  COMPOUND_PATTERNS = [
    /\b(maux?\s+(?:de|du|des|au|aux|à\s+la|à\s+l)\s+\w+)/i,
    /\b(coup\s+de\s+\w+)/i,
    /\b(rhume\s+des?\s+\w+)/i,
    /\b(crise\s+\w+)/i,
    /\b(arrêt\s+\w+)/i,
    /\b(tension\s+\w+)/i,
    /\b(pression\s+\w+)/i,
    /\b(nez\s+(?:bouché|qui\s+coule))/i,
    /\b(brûlures?\s+d\s*['']\s*estomac)/i,
  ].freeze

  def initialize(wiktionary_service:)
    @wiktionary = wiktionary_service
    load_cache
  end

  def resolve(text)
    result = text.downcase
    COMPOUND_PATTERNS.each do |pattern|
      result = result.gsub(pattern) { |match| resolve_phrase(match.strip.downcase) }
    end
    result
  end

  private

  def resolve_phrase(phrase)
    return @cache[phrase] if @cache.key?(phrase)

    synonyms = @wiktionary.find_synonyms(phrase)
    if synonyms.any?
      cache_and_return(phrase, synonyms.first, "synonyme")
      return @cache[phrase]
    end

    definition = @wiktionary.definition(phrase)
    if definition
      def_keywords = KeywordExtractorService.extract(definition).first(1)
      if def_keywords.any?
        cache_and_return(phrase, def_keywords.first, "définition")
        return @cache[phrase]
      end
    end

    Rails.logger.info "[CompoundPhraseResolverService] Expression non résolue : '#{phrase}'"
    @cache[phrase] = phrase
    save_cache
    phrase
  rescue => e
    Rails.logger.error "[CompoundPhraseResolverService] Erreur '#{phrase}' : #{e.message}"
    phrase
  end

  def cache_and_return(phrase, replacement, source)
    Rails.logger.info "[CompoundPhraseResolverService] '#{phrase}' → '#{replacement}' (#{source})"
    @cache[phrase] = replacement
    save_cache
  end

  def load_cache
    if File.exist?(CACHE_PATH)
      @cache = YAML.load_file(CACHE_PATH) || {}
      Rails.logger.info "[CompoundPhraseResolverService] Cache chargé (#{@cache.size} entrées)"
    else
      @cache = {}
    end
  end

  def save_cache
    File.write(CACHE_PATH, @cache.to_yaml)
  end
end
