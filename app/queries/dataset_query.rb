# Query Object : encapsule la logique de recherche dans le dataset (CouchDB docs).
# Supporte la correspondance exacte (normalisée) et la similarité Jaccard filtrée.
class DatasetQuery
  SIMILARITY_THRESHOLD = 0.5

  def initialize(docs)
    @docs = docs
  end

  def find_best_match(user_message)
    find_exact_match(user_message) || find_similarity_match(user_message)
  end

  private

  def find_exact_match(user_message)
    user_words = TextNormalizerService.normalize(user_message)
    exact = @docs.select { |d| d["question"] && TextNormalizerService.normalize(d["question"]) == user_words }
    exact.sample
  end

  def find_similarity_match(user_message)
    user_words_filtered = SimilarityCalculatorService.normalize_for_matching(user_message)
    best_doc   = nil
    best_score = 0.0

    @docs.each do |d|
      next unless d["question"]
      score = SimilarityCalculatorService.jaccard(user_words_filtered, SimilarityCalculatorService.normalize_for_matching(d["question"]))
      if score > best_score
        best_score = score
        best_doc   = d
      end
    end

    best_score > SIMILARITY_THRESHOLD ? best_doc : nil
  end
end
