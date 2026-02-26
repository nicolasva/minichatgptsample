# Orchestrateur principal : assemble les services et délègue chaque responsabilité.
# Toute la logique métier est répartie dans des classes dédiées (voir app/services/).
class ChatGptService
  def initialize
    @wiktionary        = WiktionaryService.new
    @intent_detector   = IntentDetectorService.new(wiktionary_service: @wiktionary)
    @compound_resolver = CompoundPhraseResolverService.new(wiktionary_service: @wiktionary)

    dataset_docs = Dataset.seed_if_empty!
    DatasetCleanerService.new(dataset_docs).cleanup!

    @dataset_query = DatasetQuery.new(dataset_docs)
    @auto_learner  = AutoLearnerService.new(dataset_docs, compound_resolver: @compound_resolver)

    wikipedia  = WikipediaService.new(intent_detector: @intent_detector)
    duckduckgo = DuckDuckGoService.new
    tavily     = TavilyService.new
    weather    = WeatherService.new

    @web_search = WebSearchOrchestratorService.new(
      wiktionary:        @wiktionary,
      wikipedia:         wikipedia,
      duckduckgo:        duckduckgo,
      tavily:            tavily,
      compound_resolver: @compound_resolver
    )

    @fallback = FallbackResponderService.new(web_search: @web_search, weather: weather)
  end

  def predict(raw_message, session_id)
    msg = UserMessage.new(raw: raw_message, session_id: session_id)
    Memory.create(session_id: session_id, role: "user", content: msg.raw)

    match = @dataset_query.find_best_match(msg.raw)

    answer = if match
      @auto_learner.learn_pending(session_id, match["answer"])
      match["answer"]
    else
      reply = @fallback.call(msg)
      @auto_learner.handle_fallback(session_id, msg, reply)
      reply
    end

    Memory.create(session_id: session_id, role: "bot", content: answer)
    answer
  end
end
