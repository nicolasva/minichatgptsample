# Gère l'apprentissage automatique :
# - pending_learns : questions sans réponse mise en attente pour un futur apprentissage
# - handle_fallback : sauvegarde la réponse web si pertinente, sinon met en attente
class AutoLearnerService

  def initialize(dataset_docs, compound_resolver:)
    @docs              = dataset_docs
    @compound_resolver = compound_resolver
    @pending           = {}
  end

  # Appelé quand on trouve une réponse dans le dataset :
  # apprend toutes les questions en attente de cette session avec cette réponse.
  def learn_pending(session_id, answer)
    pending = @pending.delete(session_id)
    return if pending.nil? || pending.empty?

    pending.each do |msg|
      next if TextNormalizerService.normalize(msg).empty?
      next if already_known?(msg)

      pair = { "question" => msg.downcase.strip, "answer" => answer }
      Dataset.create(pair)
      @docs << pair
      Rails.logger.info "[AutoLearnerService] Appris : '#{pair['question']}' => '#{pair['answer']}'"
    end
  end

  # Appelé quand on utilise la réponse de fallback.
  # Accepte un UserMessage (value object) ou une String.
  def handle_fallback(session_id, msg, answer)
    msg = UserMessage.new(raw: msg.to_s, session_id: session_id) unless msg.is_a?(UserMessage)

    if web_answer?(answer)
      save_web_answer_if_relevant(session_id, msg, answer)
    elsif !answer&.start_with?("Météo à")
      add_pending(session_id, msg.raw)
    end
  end

  private

  def save_web_answer_if_relevant(session_id, msg, answer)
    normalized_q = msg.raw.downcase.strip
    return if already_saved?(normalized_q)

    question_keywords = KeywordExtractorService.extract(@compound_resolver.resolve(msg.raw))
    relevant          = question_keywords.any? { |kw| answer.downcase.include?(kw) }

    if relevant
      pair = { "question" => normalized_q, "answer" => answer }
      Dataset.create(pair)
      @docs << pair
      Rails.logger.info "[AutoLearnerService] Appris depuis le web : '#{normalized_q}'"
    else
      Rails.logger.info "[AutoLearnerService] Réponse web non pertinente, mise en attente : '#{normalized_q}'"
      add_pending(session_id, msg.raw)
    end
  end

  def add_pending(session_id, message)
    @pending[session_id] ||= []
    @pending[session_id] << message
  end

  def already_known?(msg)
    normalized = TextNormalizerService.normalize(msg)
    @docs.any? { |d| d["question"] && TextNormalizerService.normalize(d["question"]) == normalized }
  end

  def already_saved?(normalized_q)
    @docs.any? { |d| d["question"] == normalized_q }
  end

  def web_answer?(answer)
    return false if answer.nil?
    # Délègue la qualification au SearchResult value object
    SearchResult::WEB_SOURCES.any? { |src| answer.include?(src) && answer.length > src.length + 20 }
  end
end
