require "set"
require "json"

# Nettoie les entrées apprises automatiquement depuis le web au démarrage,
# afin de repartir sur une base propre (la logique de recherche re-apprendra de meilleures réponses).
class DatasetCleanerService
  DATASET_PATH = Rails.root.join("config", "dataset.json").to_s
  WEB_PREFIXES = ["D'après Wikipedia", "D'après DuckDuckGo", "Résultats DuckDuckGo", "Résultats Tavily"].freeze

  def initialize(docs)
    @docs = docs
  end

  def cleanup!
    original_questions = load_original_questions
    removed = 0

    @docs.reject! do |doc|
      next false unless doc["answer"] && doc["question"]
      next false if original_questions.include?(doc["question"]&.downcase&.strip)

      is_web = WEB_PREFIXES.any? { |prefix| doc["answer"].start_with?(prefix) }
      next false unless is_web

      begin
        Dataset.delete(doc)
        removed += 1
      rescue => e
        Rails.logger.error "[DatasetCleanerService] Erreur suppression : #{e.message}"
      end
      true
    end

    Rails.logger.info "[DatasetCleanerService] #{removed} entrée(s) web supprimée(s)" if removed > 0
  end

  private

  def load_original_questions
    questions = Set.new
    if File.exist?(DATASET_PATH)
      JSON.parse(File.read(DATASET_PATH)).each do |d|
        questions << d["question"]&.downcase&.strip if d["question"]
      end
    end
    questions
  end
end
