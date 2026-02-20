module ChatGptServiceHelper
  # Crée une instance de ChatGptService SANS appeler initialize
  # (pas de CouchDB, pas de réseau, pas de fichiers)
  # Pour tester les méthodes pures uniquement
  def build_bare_service
    service = ChatGptService.allocate
    service.instance_variable_set(:@dataset_docs, [])
    service.instance_variable_set(:@pending_learns, {})
    service.instance_variable_set(:@compound_cache, {})
    service.instance_variable_set(:@intent_words, {})
    service.instance_variable_set(:@intent_targets, {})
    service.instance_variable_set(:@country_indicators, [])
    service
  end

  # Crée une instance avec le dataset chargé depuis le JSON
  # (pas de CouchDB, mais les données sont disponibles pour find_best_match)
  def build_service_with_dataset
    service = build_bare_service
    dataset = JSON.parse(File.read(Rails.root.join("config", "dataset.json")))
    service.instance_variable_set(:@dataset_docs, dataset)
    service
  end
end
