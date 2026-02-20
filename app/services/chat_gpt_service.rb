require "numo/narray"
require "securerandom"
require "json"
require "yaml"
require "net/http"
require "uri"
require "fileutils"
require "set"

class ChatGptService
  DATASET_PATH = Rails.root.join("config", "dataset.json").to_s
  INTENT_KEYWORDS_PATH = Rails.root.join("config", "intent_keywords.yml").to_s
  INTENT_CACHE_PATH = Rails.root.join("tmp", "intent_keywords_enriched.yml").to_s

  # Patterns pour détecter les expressions composées dans le texte
  # Ces regex capturent des formes courantes comme "mal de tête", "coup de soleil", etc.
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

  COMPOUND_CACHE_PATH = Rails.root.join("tmp", "compound_phrases_cache.yml").to_s

  def initialize
    # Charger dataset depuis CouchDB (seed depuis JSON si vide)
    @dataset_docs = Dataset.seed_if_empty!
    @pending_learns = {} # session_id => [messages non compris en attente]

    # Charger le cache des expressions composées (Wiktionary)
    load_compound_cache

    # Nettoyer les réponses web non pertinentes apprises précédemment
    cleanup_bad_learned_entries

    # Charger les mots-clés d'intention (YAML + enrichissement Wiktionary)
    load_intent_keywords
  end

  # ----- Cache des expressions composées (Wiktionary) -----
  def load_compound_cache
    if File.exist?(COMPOUND_CACHE_PATH)
      @compound_cache = YAML.load_file(COMPOUND_CACHE_PATH) || {}
      Rails.logger.info "[MiniGPT] Cache expressions composées chargé (#{@compound_cache.size} entrées)"
    else
      @compound_cache = {}
    end
  end

  def save_compound_cache
    File.write(COMPOUND_CACHE_PATH, @compound_cache.to_yaml)
  end

  # Supprime TOUTES les entrées apprises automatiquement depuis le web
  # pour repartir proprement (la logique de recherche améliorée re-apprendra de meilleures réponses)
  def cleanup_bad_learned_entries
    # Préfixes sans le séparateur final (espace, newline) pour un matching plus robuste
    web_prefixes = ["D'après Wikipedia", "D'après DuckDuckGo", "Résultats DuckDuckGo", "Résultats Tavily"]
    removed = 0

    # Charger le dataset original du fichier JSON pour savoir quelles entrées sont "de base"
    original_questions = Set.new
    if File.exist?(DATASET_PATH)
      JSON.parse(File.read(DATASET_PATH)).each do |d|
        original_questions << d["question"]&.downcase&.strip if d["question"]
      end
    end

    @dataset_docs.reject! do |doc|
      next false unless doc["answer"] && doc["question"]
      # Garder les entrées du dataset original
      next false if original_questions.include?(doc["question"]&.downcase&.strip)
      # Supprimer toutes les entrées apprises depuis le web
      is_web = web_prefixes.any? { |prefix| doc["answer"].start_with?(prefix) }
      next false unless is_web

      begin
        Dataset.delete(doc)
        removed += 1
      rescue => e
        Rails.logger.error "[MiniGPT] Erreur suppression doc CouchDB : #{e.message}"
      end
      true # reject this doc
    end

    Rails.logger.info "[MiniGPT] Nettoyage : #{removed} entrée(s) web supprimée(s) de CouchDB" if removed > 0
  end

  # ----- Chargement des mots-clés d'intention -----
  def load_intent_keywords
    # Essayer le cache enrichi d'abord (évite les appels Wiktionary à chaque démarrage)
    if File.exist?(INTENT_CACHE_PATH) && File.mtime(INTENT_CACHE_PATH) > File.mtime(INTENT_KEYWORDS_PATH)
      cached = YAML.load_file(INTENT_CACHE_PATH)
      @intent_words = cached["intent_words"].transform_keys(&:to_sym)
      @intent_targets = cached["intent_targets"].transform_keys(&:to_sym)
      @country_indicators = cached["country_indicators"]
      Rails.logger.info "[MiniGPT] Mots-clés d'intention chargés depuis le cache (#{@intent_words.values.map(&:size).sum} mots)"
      return
    end

    # Charger le YAML de base
    config = YAML.load_file(INTENT_KEYWORDS_PATH)
    intents = config["intents"]

    @intent_words = {}
    @intent_targets = {}

    intents.each do |name, data|
      key = name.to_sym
      base_words = (data["seeds"] || []) + (data["extra_words"] || [])

      # Enrichir les seeds avec les synonymes Wiktionary
      enriched = []
      (data["seeds"] || []).each do |seed|
        synonyms = find_synonyms(seed)
        enriched.concat(synonyms)
        Rails.logger.info "[MiniGPT] Enrichissement '#{seed}' : +#{synonyms.size} synonymes (#{synonyms.join(', ')})" if synonyms.any?
      end

      @intent_words[key] = (base_words + enriched).map(&:downcase).uniq
      @intent_targets[key] = (data["target_sections"] || []).map(&:downcase).uniq
    end

    @country_indicators = (config["country_indicators"] || []).map(&:downcase).uniq

    # Sauvegarder le cache enrichi
    cache_data = {
      "intent_words" => @intent_words.transform_keys(&:to_s),
      "intent_targets" => @intent_targets.transform_keys(&:to_s),
      "country_indicators" => @country_indicators
    }
    FileUtils.mkdir_p(File.dirname(INTENT_CACHE_PATH))
    File.write(INTENT_CACHE_PATH, cache_data.to_yaml)
    Rails.logger.info "[MiniGPT] Mots-clés enrichis et mis en cache (#{@intent_words.values.map(&:size).sum} mots)"
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur chargement intent_keywords : #{e.message}"
    # Fallback : listes vides (le code continuera à fonctionner avec les fallbacks)
    @intent_words = {}
    @intent_targets = {}
    @country_indicators = []
  end

  # ----- Normalisation -----
  def normalize(text)
    # Remplacer les apostrophes et tirets par des espaces pour séparer
    # "l'hopital" → "l" + "hopital", "saint-malo" → "saint" + "malo"
    text.downcase.gsub(/['''`\u2018\u2019\-]/, " ").gsub(/[^a-zà-ÿ0-9\s]/, "").split
  end

  # Mots trop communs qui créent des faux positifs dans le matching Jaccard
  # Inclut les verbes courants, prépositions, et mots génériques de questions
  MATCHING_STOP_WORDS = %w[
    je tu il elle on nous vous ils elles
    le la les l un une des de du au aux en
    a à est es et ou où ni ne pas
    me te se ce ça sa son ses mon ma mes ton ta tes
    qui que quoi dont quel quelle quels quelles
    film films acteur acteurs actrice actrices
    connais sais dire dis peux peut faire fait
    sont pour par sur dans avec sans vers chez entre contre
    comment pourquoi quand combien
    être avoir être etre fait font va vont sera serait
    faut falloir prendre donner utiliser
    aussi très bien plus moins tout tous toute toutes
    cette cet ces autre autres encore même
    médicament médicaments traitement traitements remède remèdes
    soigner guérir prendre soulager traiter
  ].freeze

  def normalize_for_matching(text)
    normalize(text).reject { |w| MATCHING_STOP_WORDS.include?(w) || w.length < 2 }
  end

  # ----- Similarité par mots (Jaccard) -----
  def jaccard_similarity(words_a, words_b)
    return 0.0 if words_a.empty? || words_b.empty?
    intersection = (words_a & words_b).size.to_f
    union = (words_a | words_b).size.to_f
    union.zero? ? 0.0 : intersection / union
  end

  def find_best_match(user_message)
    user_words = normalize(user_message)
    user_words_filtered = normalize_for_matching(user_message)

    # Match exact d'abord (normalisé)
    exact = @dataset_docs.select { |d|
      d["question"] && normalize(d["question"]) == user_words
    }
    return exact.sample if exact.any?

    # Sinon, similarité Jaccard (avec mots filtrés pour éviter les faux positifs)
    best_doc = nil
    best_score = 0.0

    @dataset_docs.each do |d|
      next unless d["question"]
      score = jaccard_similarity(user_words_filtered, normalize_for_matching(d["question"]))
      if score > best_score
        best_score = score
        best_doc = d
      end
    end

    best_score > 0.5 ? best_doc : nil
  end

  # ----- Mémoire -----
  def load_memory(session_id)
    Memory.find_by_session(session_id)
  end

  def save_memory(session_id, role, content)
    Memory.create(session_id: session_id, role: role, content: content)
  end

  # ----- Fallback par sentiment/type -----
  POSITIVE_WORDS = %w[bien super génial parfait parfaitement cool top excellent magnifique content contente heureux heureuse formidable nickel impeccable extra chouette trop adore aime j'adore j'aime fantastique merveilleux].freeze
  NEGATIVE_WORDS = %w[mal triste nul horrible mauvais moche ennui ennuie fatigue fatigué peur stress stressé déprimé marre chiant pénible pas terrible bof].freeze
  QUESTION_WORDS = %w[qui que quoi quel quelle quels quelles où comment pourquoi quand combien est-ce].freeze
  WEATHER_WORDS = %w[temps météo meteo température temperature climat pluie soleil neige vent chaud froid].freeze
  CITY_PREPOSITIONS = %w[à a au en sur].freeze

  POSITIVE_RESPONSES = [
    "Super ! Ça fait plaisir à entendre !",
    "Génial ! Content pour toi !",
    "Top ! Continue comme ça !",
    "Ça fait plaisir ! 😊"
  ].freeze

  NEGATIVE_RESPONSES = [
    "Oh, désolé d'entendre ça. Tu veux en parler ?",
    "Courage ! Ça va aller mieux.",
    "Je suis là si tu as besoin de parler.",
    "Pas facile... Qu'est-ce qui ne va pas ?"
  ].freeze

  QUESTION_RESPONSES = [
    "Bonne question ! Malheureusement je n'ai pas la réponse.",
    "Hmm, je ne suis pas sûr. Essaie de reformuler !",
    "Je ne connais pas la réponse, mais c'est intéressant comme question !"
  ].freeze

  DEFAULT_RESPONSES = [
    "Intéressant ! Dis-m'en plus.",
    "D'accord ! Quoi d'autre ?",
    "Je vois ! Continue.",
    "Ah oui ? Raconte-moi plus !",
    "C'est noté ! Autre chose ?"
  ].freeze

    # Détecte les questions d'opinion/oui-non qui ne nécessitent pas de recherche web
  # Ex: "est-ce que la ville est belle ?", "tu trouves ça bien ?", "c'est joli ?"
  OPINION_ADJECTIVES = %w[
    beau belle beaux belles joli jolie jolis jolies moche moches
    bien mal bon bonne bons bonnes mauvais mauvaise
    grand grande grands grandes petit petite petits petites
    intéressant intéressante ennuyeux ennuyeuse
    facile difficile important importante normal normale
    vrai vraie faux fausse possible impossible
    sympa gentil gentille méchant méchante
  ].freeze

  def fallback_response(message)
    words = normalize(message)

    if words.any? { |w| WEATHER_WORDS.include?(w) }
      weather_answer = search_weather(message)
      return weather_answer if weather_answer
    end

    # Prioriser les questions (même si le message contient des mots négatifs)
    # Mais ignorer les questions d'opinion/conversationnelles (pas de réponse factuelle)
    if is_question?(message, words) && !opinion_question?(message)
      web_answer = search_web(message)
      web_answer || QUESTION_RESPONSES.sample
    elsif is_question?(message, words) && opinion_question?(message)
      QUESTION_RESPONSES.sample
    elsif words.any? { |w| POSITIVE_WORDS.include?(w) }
      POSITIVE_RESPONSES.sample
    elsif words.any? { |w| NEGATIVE_WORDS.include?(w) }
      NEGATIVE_RESPONSES.sample
    else
      DEFAULT_RESPONSES.sample
    end
  end

  def is_question?(message, words = nil)
    words ||= normalize(message)
    message.include?("?") || words.any? { |w| QUESTION_WORDS.include?(w) }
  end

  def opinion_question?(message)
    msg = message.downcase
    words = normalize(message)
    # Pattern "est-ce que" / "est que" / "c'est" + adjectif subjectif
    has_opinion_pattern = msg.match?(/\b(est[\s\-]ce\s+que?\b|est\s+que?\b|c\s*est\b|tu\s+trouves?\b|tu\s+penses?\b|tu\s+crois?\b|tu\s+aimes?\b)/i)
    has_adjective = words.any? { |w| OPINION_ADJECTIVES.include?(w) }
    # C'est une question d'opinion si elle a le pattern + un adjectif subjectif
    has_opinion_pattern && has_adjective
  end

  # ----- Météo (wttr.in) -----
  def search_weather(message)
    city = extract_city(message)
    city = "Paris" if city.nil? || city.empty?

    encoded_city = URI.encode_www_form_component(city)
    uri = URI("https://wttr.in/#{encoded_city}?format=j1&lang=fr")
    response = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    data = JSON.parse(response.body)
    current = data["current_condition"]&.first
    return nil unless current

    temp = current["temp_C"]
    feels_like = current["FeelsLikeC"]
    humidity = current["humidity"]
    description = current.dig("lang_fr", 0, "value") || current.dig("weatherDesc", 0, "value")

    "Météo à #{city.capitalize} : #{description}, #{temp}°C (ressenti #{feels_like}°C), humidité #{humidity}%."
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur météo : #{e.message}"
    nil
  end

  def extract_city(message)
    words = message.downcase.gsub(/[?!.,]/, "").split
    # Chercher le mot après une préposition de lieu (à, au, en, sur)
    words.each_with_index do |w, i|
      if CITY_PREPOSITIONS.include?(w) && words[i + 1]
        # Prendre tous les mots qui suivent la préposition (pour "New York", "Los Angeles", etc.)
        city_parts = []
        (i + 1...words.size).each do |j|
          break if WEATHER_WORDS.include?(words[j]) || QUESTION_WORDS.include?(words[j]) || %w[aujourd'hui demain ce cette].include?(words[j])
          city_parts << words[j]
        end
        return city_parts.join(" ") if city_parts.any?
      end
    end
    nil
  end

  # ----- Expressions composées -----
  # Détecte les expressions composées dans le texte et les remplace par un terme plus précis
  # via le Wiktionnaire français (avec cache disque pour éviter les appels répétés)
  def replace_compound_phrases(text)
    result = text.downcase

    COMPOUND_PATTERNS.each do |pattern|
      result = result.gsub(pattern) do |match|
        phrase = match.strip.downcase
        resolve_compound_phrase(phrase)
      end
    end

    result
  end

  # Résout une expression composée : cherche dans le cache, puis sur Wiktionary
  def resolve_compound_phrase(phrase)
    # 1. Vérifier le cache mémoire/disque
    return @compound_cache[phrase] if @compound_cache.key?(phrase)

    # 2. Chercher sur Wiktionary (synonymes de l'expression complète)
    synonyms = find_synonyms(phrase)
    if synonyms.any?
      # Prendre le premier synonyme (le plus courant/pertinent)
      replacement = synonyms.first
      Rails.logger.info "[MiniGPT] Expression composée via Wiktionary : '#{phrase}' → '#{replacement}'"
      @compound_cache[phrase] = replacement
      save_compound_cache
      return replacement
    end

    # 3. Chercher la définition sur Wiktionary pour extraire un terme clé
    definition = wiki_definition(phrase)
    if definition
      # Extraire le premier mot significatif de la définition (souvent le terme médical)
      def_keywords = extract_keywords(definition).first(1)
      if def_keywords.any?
        replacement = def_keywords.first
        Rails.logger.info "[MiniGPT] Expression composée via définition Wiktionary : '#{phrase}' → '#{replacement}'"
        @compound_cache[phrase] = replacement
        save_compound_cache
        return replacement
      end
    end

    # 4. Aucun résultat trouvé : garder l'expression telle quelle et cacher le résultat négatif
    Rails.logger.info "[MiniGPT] Expression composée non résolue : '#{phrase}'"
    @compound_cache[phrase] = phrase
    save_compound_cache
    phrase
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur résolution expression composée '#{phrase}' : #{e.message}"
    phrase
  end

  # ----- Recherche Internet (avec 3 niveaux de compréhension) -----
  def search_web(query)
    # === Pré-traitement : remplacer les expressions composées ===
    enriched_query = replace_compound_phrases(query)
    if enriched_query != query.downcase
      Rails.logger.info "[MiniGPT] Expressions composées détectées : '#{query}' → '#{enriched_query}'"
    end

    # === Recherche directe (avec la requête enrichie en priorité) ===
    if enriched_query != query.downcase
      result = search_direct(enriched_query)
      return result if result
    end
    result = search_direct(query)
    return result if result

    keywords = extract_keywords(enriched_query)
    return nil if keywords.empty?

    # === Niveau 1 : Synonymes (Wiktionary) ===
    Rails.logger.info "[MiniGPT] Recherche directe échouée, essai avec synonymes..."
    result = search_with_synonyms(enriched_query, keywords)
    return result if result && extract_relevant?(result, query)

    # === Niveau 2 : Définition Wikipedia des mots-clés ===
    Rails.logger.info "[MiniGPT] Synonymes échoués, essai avec définitions Wikipedia..."
    result = search_with_definitions(enriched_query, keywords)
    return result if result && extract_relevant?(result, query)

    # === Niveau 3 : Correction orthographique (Wiktionary) ===
    Rails.logger.info "[MiniGPT] Définitions échouées, essai avec correction orthographique..."
    result = search_with_spelling_correction(enriched_query, keywords)
    return result if result && extract_relevant?(result, query)

    # === Dernier recours : Wikipedia FR par mot-clé individuel ===
    Rails.logger.info "[MiniGPT] Correction échouée, essai Wikipedia par mot-clé individuel..."
    extract = wiki_search_individual("fr", keywords, enriched_query)
    if extract
      full_result = "D'après Wikipedia : #{extract}"
      return full_result if extract_relevant?(full_result, query)
    end

    nil
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur recherche web : #{e.message}"
    nil
  end

  # Recherche directe : Tavily → DuckDuckGo → DuckDuckGo Web → Wikipedia (mode strict)
  def search_direct(query)
    # Wikipedia avant DuckDuckGo Web car ce dernier ne retourne que des titres de liens
    search_tavily(query) || search_duckduckgo(query) || search_wikipedia(query) || search_duckduckgo_web(query)
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur recherche directe : #{e.message}"
    nil
  end

  # Recherche relaxée : Tavily → DuckDuckGo → DuckDuckGo Web → Wikipedia (mode relaxé pour synonymes/définitions)
  def search_relaxed(query)
    search_tavily(query) || search_duckduckgo(query) || search_wikipedia_relaxed(query) || search_duckduckgo_web(query)
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur recherche relaxée : #{e.message}"
    nil
  end

  def search_wikipedia_relaxed(query)
    keywords = extract_keywords(query)
    return nil if keywords.empty?
    extract = wiki_search_relaxed("fr", keywords, query)
    return nil if extract.nil?
    "D'après Wikipedia : #{extract}"
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur Wikipedia relaxé : #{e.message}"
    nil
  end

  def wiki_search_relaxed(lang, keywords, original_query = "")
    wiki_query(lang, keywords.join(" "), original_query, relaxed: true)
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur Wikipedia relaxé #{lang} : #{e.message}"
    nil
  end

  # Niveau 1 : Remplacer chaque mot-clé par ses synonymes et réessayer
  def search_with_synonyms(query, keywords)
    keywords.each do |word|
      synonyms = find_synonyms(word)
      next if synonyms.empty?
      Rails.logger.info "[MiniGPT] Synonymes de '#{word}' : #{synonyms.join(', ')}"

      synonyms.each do |syn|
        # Remplacer le mot par son synonyme dans la requête
        new_query = query.gsub(/#{Regexp.escape(word)}/i, syn)
        result = search_relaxed(new_query)
        return result if result
      end
    end
    nil
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur synonymes : #{e.message}"
    nil
  end

  # Niveau 2 : Chercher la définition Wikipedia de chaque mot-clé pour mieux comprendre
  def search_with_definitions(query, keywords)
    # Chercher les mots-clés les plus longs en premier (plus spécifiques)
    keywords.sort_by { |w| -w.length }.each do |word|
      definition = wiki_definition(word)
      next if definition.nil?
      Rails.logger.info "[MiniGPT] Définition de '#{word}' : #{definition[0..80]}..."

      # Extraire les 2 meilleurs mots de la définition
      definition_keywords = extract_keywords(definition).first(2)
      next if definition_keywords.empty?

      # Remplacer le mot inconnu par ses termes de définition dans les autres mots-clés
      other_keywords = keywords.reject { |k| k == word }
      new_queries = definition_keywords.map { |dk| (other_keywords + [dk]).join(" ") }

      new_queries.each do |nq|
        Rails.logger.info "[MiniGPT] Recherche enrichie : '#{nq}'"
        result = search_relaxed(nq)
        return result if result
      end
    end
    nil
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur définitions : #{e.message}"
    nil
  end

  # Niveau 3 : Corriger l'orthographe via Wiktionary et réessayer
  def search_with_spelling_correction(query, keywords)
    corrected_keywords = keywords.map { |w| correct_spelling(w) || w }
    return nil if corrected_keywords == keywords # Pas de correction trouvée

    corrected_query = corrected_keywords.join(" ")
    Rails.logger.info "[MiniGPT] Correction orthographique : #{keywords.join(' ')} → #{corrected_query}"
    search_direct(corrected_query)
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur correction : #{e.message}"
    nil
  end

  # ----- Wiktionary : Synonymes -----
  def find_synonyms(word)
    encoded = URI.encode_www_form_component(word.downcase)
    uri = URI("https://fr.wiktionary.org/w/api.php?action=parse&page=#{encoded}&prop=wikitext&format=json")
    response = Net::HTTP.get_response(uri)
    return [] unless response.code == "200"

    data = JSON.parse(response.body)
    wikitext = data.dig("parse", "wikitext", "*")
    return [] if wikitext.nil?

    synonyms = []
    in_synonyms = false
    wikitext.split("\n").each do |line|
      if line.include?("{{S|synonymes")
        in_synonyms = true
        next
      end
      if in_synonyms
        break if line.match?(/\{\{S\|/)
        m = line.match(/\[\[([^\]|#]+)/)
        if m
          syn = m[1].strip.downcase
          synonyms << syn unless syn.empty?
        end
      end
    end

    synonyms.first(5)
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur Wiktionary synonymes : #{e.message}"
    []
  end

  # ----- Wiktionary : Définition courte -----
  def wiki_definition(word)
    encoded = URI.encode_www_form_component(word.downcase)
    uri = URI("https://fr.wiktionary.org/w/api.php?action=parse&page=#{encoded}&prop=wikitext&format=json")
    response = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    data = JSON.parse(response.body)
    wikitext = data.dig("parse", "wikitext", "*")
    return nil if wikitext.nil?

    # Extraire la première définition (ligne commençant par #)
    wikitext.split("\n").each do |line|
      next unless line.match?(/\A#[^#*:]/)
      # Nettoyer le wikitext : enlever les balises [[...]], {{...}}, etc.
      clean = line.sub(/\A#+\s*/, "")
      clean = clean.gsub(/\{\{[^}]*\}\}/, "")
      clean = clean.gsub(/\[\[(?:[^|\]]*\|)?([^\]]*)\]\]/, '\1')
      clean = clean.gsub(/'{2,}/, "").strip
      return clean unless clean.empty?
    end

    nil
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur Wiktionary définition : #{e.message}"
    nil
  end

  # ----- Wiktionary : Correction orthographique -----
  def correct_spelling(word)
    encoded = URI.encode_www_form_component(word.downcase)
    uri = URI("https://fr.wiktionary.org/w/api.php?action=query&list=search&srsearch=#{encoded}&srlimit=1&format=json")
    response = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    data = JSON.parse(response.body)
    # Si le mot n'existe pas directement, Wiktionary peut suggérer une correction
    suggestion = data.dig("query", "searchinfo", "suggestion")
    return suggestion if suggestion && suggestion != word.downcase

    # Vérifier si le premier résultat est une correction probable
    results = data.dig("query", "search")
    if results && !results.empty?
      title = results.first["title"].downcase
      return title if title != word.downcase && levenshtein_close?(word.downcase, title)
    end

    nil
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur Wiktionary correction : #{e.message}"
    nil
  end

  # Supprime les accents d'un mot (é→e, è→e, ê→e, à→a, ù→u, etc.)
  def strip_accents(word)
    word.tr("àâäáãåèéêëìíîïòóôöõùúûüýÿñç", "aaaaaaeeeeiiiiooooouuuuyync")
  end

  # Stemming français simplifié : vérifie si deux mots sont des variantes
  # Gère : singulier/pluriel, accents, et terminaisons verbales courantes (é/er/e/ée)
  def stem_match?(word_a, word_b)
    return true if word_a == word_b

    # Comparer sans accents
    a = strip_accents(word_a)
    b = strip_accents(word_b)
    return true if a == b

    # Pluriels courants : -s, -es, -x
    return true if a + "s" == b || b + "s" == a
    return true if a + "es" == b || b + "es" == a
    return true if a + "x" == b || b + "x" == a
    # -aux / -al (ex: national/nationaux)
    return true if a.sub(/aux\z/, "al") == b || b.sub(/aux\z/, "al") == a
    # Terminaisons verbales françaises : joué/joue/jouer/jouée/jouées
    a_stem = a.sub(/(er|ee?s?|ant|ent)\z/, "")
    b_stem = b.sub(/(er|ee?s?|ant|ent)\z/, "")
    return true if a_stem == b_stem && a_stem.length >= 3
    false
  end

  # Compte les mots de search_words qui matchent (exact ou stem) avec title_words
  def stem_match_count(search_words, title_words)
    search_words.count { |sw| title_words.any? { |tw| stem_match?(sw, tw) } }
  end

  # Vérifie que l'extrait Wikipedia est pertinent par rapport à la question
  # Vérifie la PREMIÈRE PHRASE de l'extrait (qui décrit de quoi parle l'article)
  # Rejette les faux positifs comme "Le Grand Continent" (revue) pour "continent le plus visité"
  # ou "Coupe du monde de ski alpin" pour "continent le plus visité dans le monde"
  # ou "Benoît XVI visites pastorales" pour "continent le plus visité"
  def extract_relevant?(extract, query)
    return true if query.nil? || query.empty?

    query_kw = extract_keywords(query)
    return true if query_kw.empty? || query_kw.size <= 1

    # Vérifier la première phrase (avant le premier "." ou "\n")
    # La première phrase décrit de quoi parle l'article
    intro = extract.split(/[.\n]/).first.to_s
    intro_normalized = strip_accents(intro.downcase)
    matched = query_kw.count { |kw| intro_normalized.include?(strip_accents(kw)) }

    # Seuil strict : ceil(n * 2/3) — pour 2 mots-clés, il faut les DEUX ;
    # pour 3, il faut au moins 2 ; pour 4, il faut 3
    min_needed = [(query_kw.size * 2 / 3.0).ceil, 1].max

    matched >= min_needed
  end

  # Distance de Levenshtein simplifiée : les mots sont-ils proches ?
  def levenshtein_close?(a, b)
    return true if a == b
    return false if (a.length - b.length).abs > 2

    # Calcul simplifié : compter les caractères différents
    max_len = [a.length, b.length].max
    common = 0
    [a.length, b.length].min.times { |i| common += 1 if a[i] == b[i] }
    common.to_f / max_len > 0.7
  end

  # DuckDuckGo HTML : vrais résultats web (fallback quand l'API Instant Answer ne retourne rien)
  def search_duckduckgo_web(query)
    keywords = extract_keywords(query)
    return nil if keywords.empty?
    search_term = URI.encode_www_form_component(keywords.join(" "))
    uri = URI("https://html.duckduckgo.com/html/?q=#{search_term}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    response = http.request(request)
    return nil unless response.code == "200"

    html = response.body
    # Vérifier qu'on n'a pas un captcha
    return nil if html.include?("anomaly-modal") || html.include?("captcha")

    # Extraire les titres et liens des résultats
    results = []
    html.scan(/<a rel="nofollow" class="result__a" href="[^"]*">(.*?)<\/a>/) do |match|
      title = match[0].gsub(/<[^>]*>/, "").gsub("&amp;", "&").gsub("&#x27;", "'").gsub("&quot;", '"').strip
      results << title unless title.empty?
    end

    return nil if results.empty?
    "Résultats DuckDuckGo :\n#{results.first(3).join("\n")}"
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur DuckDuckGo Web : #{e.message}"
    nil
  end

  def search_tavily(query)
    api_key = ENV["TAVILY_API_KEY"]
    return nil if api_key.nil? || api_key.empty?

    keywords = extract_keywords(query)
    return nil if keywords.empty?

    uri = URI("https://api.tavily.com/search")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{api_key}"
    request.body = {
      query: keywords.join(" "),
      search_depth: "basic",
      max_results: 3,
      include_answer: false,
      country: "France"
    }.to_json

    response = http.request(request)
    return nil unless response.code == "200"

    data = JSON.parse(response.body)
    results = data["results"]
    return nil if results.nil? || results.empty?

    answers = results.first(3).map do |item|
      title = item["title"]
      snippet = item["content"]&.gsub("\n", " ")
      "#{title} : #{snippet}"
    end

    "Résultats Tavily :\n#{answers.join("\n")}"
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur Tavily : #{e.message}"
    nil
  end

  def search_duckduckgo(query)
    # Extraire les mots-clés pour une meilleure recherche
    keywords = extract_keywords(query)
    return nil if keywords.empty?
    search_term = URI.encode_www_form_component(keywords.join(" "))
    uri = URI("https://api.duckduckgo.com/?q=#{search_term}&format=json&no_html=1&skip_disambig=1&lang=fr")
    response = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    data = JSON.parse(response.body)

    # Réponse instantanée (Abstract)
    abstract = data["AbstractText"]
    return "D'après DuckDuckGo : #{abstract}" if abstract && !abstract.empty?

    # Réponse directe (Answer)
    answer = data["Answer"]
    return "D'après DuckDuckGo : #{answer}" if answer && !answer.empty?

    # Topics associés
    topics = data["RelatedTopics"]
    if topics && !topics.empty?
      first_topic = topics.first
      if first_topic.is_a?(Hash) && first_topic["Text"] && !first_topic["Text"].empty?
        return "D'après DuckDuckGo : #{first_topic['Text']}"
      end
    end

    nil
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur DuckDuckGo : #{e.message}"
    nil
  end

  def search_wikipedia(query)
    keywords = extract_keywords(query)
    return nil if keywords.empty?

    # Pour les questions sur les pays/listes, essayer d'abord une recherche plus spécifique
    query_words = normalize(query)
    indicators = @country_indicators.any? ? @country_indicators : %w[pays état nation puissance puissant]
    if query_words.any? { |qw| indicators.any? { |w| stem_match?(qw, w) } }
      # Essai 1 : reformuler avec "grande puissance" si la question parle de puissance/puissant
      has_power_word = query_words.any? { |qw| %w[puissant puissants puissantes puissance puissances].any? { |w| stem_match?(qw, w) } }
      if has_power_word
        power_keywords = ["grande", "puissance", "pays"]
        Rails.logger.info "[MiniGPT] Recherche Wikipedia grandes puissances : #{power_keywords.join(' ')}"
        extract = wiki_search("fr", power_keywords, query)
        return "D'après Wikipedia : #{extract}" if extract
      end

      # Essai 2 : mots-clés sans les indicateurs de pays (ex: "g8" sans "pays")
      # Prioritaire car le topic direct est souvent plus pertinent que "liste + topic"
      topic_only = keywords.reject { |k| indicators.any? { |w| stem_match?(k, w) } }
      if topic_only.any? && topic_only != keywords
        # Filtrer les verbes conjugués pour ne garder que les noms/acronymes spécifiques
        # Ex: "composent g8" → "g8", "possèdent nucléaire" → "nucléaire"
        core_topic = topic_only.reject { |w| w.match?(/\A[a-zà-ÿ]+(ent|ons|ez|aient|ront|raient)\z/) }
        core_topic = topic_only if core_topic.empty?

        # 2a : mots-clés topic filtrés (sans les verbes)
        Rails.logger.info "[MiniGPT] Recherche Wikipedia topic principal : #{core_topic.join(' ')}"
        extract = wiki_search("fr", core_topic, query)
        return "D'après Wikipedia : #{extract}" if extract

        # 2b : tous les mots topic ensemble (si différent de 2a)
        if core_topic != topic_only
          Rails.logger.info "[MiniGPT] Recherche Wikipedia topic complet : #{topic_only.join(' ')}"
          extract = wiki_search("fr", topic_only, query)
          return "D'après Wikipedia : #{extract}" if extract
        end
      end

      # Essai 3 : "liste" + tous les mots-clés (fallback pour les questions de type listes)
      specific_keywords = ["liste"] + keywords
      Rails.logger.info "[MiniGPT] Recherche Wikipedia spécifique pays : #{specific_keywords.join(' ')}"
      extract = wiki_search("fr", specific_keywords, query)
      return "D'après Wikipedia : #{extract}" if extract
    end

    # Pour les questions superlatifs ("le/la plus...", "le/la moins..."), chercher avec "liste"
    # Ex: "ville la plus visitée" → "liste ville visitée", "fleuve le plus long" → "liste fleuve long"
    if query.match?(/\b(le|la|les)\s+(plus|moins)\b/i)
      list_keywords = ["liste"] + keywords
      Rails.logger.info "[MiniGPT] Recherche Wikipedia superlatif : #{list_keywords.join(' ')}"
      extract = wiki_search("fr", list_keywords, query)
      # Vérifier la pertinence car "liste" + keywords peut donner des faux positifs
      # (ex: "Le Grand Continent" = revue ≠ "continent le plus visité")
      if extract && extract_relevant?(extract, query)
        return "D'après Wikipedia : #{extract}"
      elsif extract
        Rails.logger.info "[MiniGPT] Recherche superlatif non pertinente, passage à la recherche standard"
      end
    end

    # Pour les questions de casting (qui a joué dans...), essayer avec "film" d'abord
    # car les pages de franchise (ex: "Mission impossible") n'ont souvent pas de section Distribution
    if @intent_words[:cast]&.any? { |w| query_words.any? { |qw| stem_match?(qw, w) } }
      film_keywords = keywords + ["film"]
      Rails.logger.info "[MiniGPT] Recherche Wikipedia cast+film : #{film_keywords.join(' ')}"
      extract = wiki_search("fr", film_keywords, query)
      return "D'après Wikipedia : #{extract}" if extract
    end

    # Recherche standard
    extract = wiki_search("fr", keywords, query)

    return nil if extract.nil?

    # Vérifier la pertinence pour éviter les faux positifs (ex: "Le Grand Continent" ≠ continent)
    unless extract_relevant?(extract, query)
      Rails.logger.info "[MiniGPT] Wikipedia standard non pertinent, ignoré"
      return nil
    end

    "D'après Wikipedia : #{extract}"
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur Wikipedia : #{e.message}"
    nil
  end

  def wiki_search(lang, keywords, original_query = "")
    # Chercher tous les mots-clés ensemble (pas de fallback individuel ici)
    wiki_query(lang, keywords.join(" "), original_query)
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur Wikipedia #{lang} : #{e.message}"
    nil
  end

  # Recherche Wikipedia par mots-clés individuels (dernier recours)
  def wiki_search_individual(lang, keywords, original_query = "")
    keywords.sort_by { |w| -w.length }.each do |keyword|
      result = wiki_query(lang, keyword, original_query)
      return result if result
    end
    nil
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur Wikipedia individuel #{lang} : #{e.message}"
    nil
  end

  def wiki_query(lang, search_text, original_query = "", relaxed: false)
    search_term = URI.encode_www_form_component(search_text)
    uri = URI("https://#{lang}.wikipedia.org/w/api.php?action=query&list=search&srsearch=#{search_term}&srlimit=5&format=json")
    response = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    data = JSON.parse(response.body)
    results = data.dig("query", "search")

    # Si pas de résultat, utiliser la suggestion de Wikipedia (correction orthographique)
    if results.nil? || results.empty?
      suggestion = data.dig("query", "searchinfo", "suggestion")
      if suggestion
        Rails.logger.info "[MiniGPT] Wikipedia #{lang} suggestion : #{suggestion}"
        return wiki_query(lang, suggestion, original_query, relaxed: relaxed)
      end
      return nil
    end

    search_words = normalize(search_text)
    min_required = [(search_words.size / 2.0).ceil, 1].max

    # Scorer chaque résultat en combinant titre + snippet pour un matching plus précis
    matching_results = []

    results.each_with_index do |r, idx|
      title_words = normalize(r["title"])
      snippet_text = r["snippet"].to_s.gsub(/<[^>]*>/, "").gsub(/&#0*39;/, "'").gsub(/&amp;/, "&").gsub(/&quot;/, '"').downcase
      snippet_words = normalize(snippet_text)

      # Score = mots matchés dans le titre + mots supplémentaires trouvés dans le snippet
      title_match = stem_match_count(search_words, title_words)
      # Compter les mots qui ne sont PAS dans le titre mais SONT dans le snippet
      unmatched_in_title = search_words.reject { |sw| title_words.any? { |tw| stem_match?(sw, tw) } }
      snippet_bonus = stem_match_count(unmatched_in_title, snippet_words)

      # unique_matches = nombre de mots uniques trouvés (pour le seuil minimum)
      # weighted_score = score pondéré pour le tri (titre vaut 2x plus que snippet,
      #   car un article dont le titre matche est ABOUT le sujet, pas juste le mentionne)
      unique_matches = title_match + snippet_bonus
      weighted_score = title_match * 2 + snippet_bonus
      matching_results << { result: r, title_match: title_match, snippet_bonus: snippet_bonus, total_score: unique_matches, weighted_score: weighted_score, index: idx } if unique_matches >= min_required
    end

    # Trier : meilleur score pondéré → plus de mots dans le titre → ordre Wikipedia
    matching_results.sort_by! { |m| [-m[:weighted_score], -m[:title_match], m[:index]] }

    # Essayer chaque résultat jusqu'à obtenir un extrait non vide
    matching_results.each do |m|
      page_title = m[:result]["title"]
      Rails.logger.info "[MiniGPT] Wikipedia #{lang} essai : #{page_title} (weighted=#{m[:weighted_score]}, titre=#{m[:title_match]}, snippet=#{m[:snippet_bonus]})"
      extract = wiki_extract(lang, page_title, original_query)
      return extract if extract
    end

    # 2ème passage (mode relaxé uniquement) : résultats avec assez de mots dans titre+snippet
    if relaxed
      results.each do |r|
        next if matching_results.any? { |m| m[:result]["title"] == r["title"] }
        title_words = normalize(r["title"])
        snippet = r["snippet"].to_s.gsub(/<[^>]*>/, "").downcase
        found_words = search_words.select { |w| title_words.include?(w) || snippet.include?(w) }
        if found_words.size >= min_required
          Rails.logger.info "[MiniGPT] Wikipedia #{lang} essai relaxé : #{r["title"]}"
          extract = wiki_extract(lang, r["title"], original_query)
          return extract if extract
        end
      end
    end

    Rails.logger.info "[MiniGPT] Wikipedia #{lang} aucun résultat pertinent pour '#{search_text}'"
    nil
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur wiki_query : #{e.message}"
    nil
  end

  def wiki_extract(lang, page_title, original_query = "")
    encoded_title = URI.encode_www_form_component(page_title)
    uri = URI("https://#{lang}.wikipedia.org/w/api.php?action=query&titles=#{encoded_title}&prop=extracts&explaintext=1&redirects=1&format=json")
    response = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    data = JSON.parse(response.body)
    pages = data.dig("query", "pages")
    return nil if pages.nil?

    page = pages.values.first
    full_text = page&.dig("extract")
    return nil if full_text.nil? || full_text.strip.empty?

    # Gérer les pages de désambiguïsation / homonymie
    if full_text.include?("peut faire référence") || full_text.include?("peut désigner") ||
       full_text.include?("Cette page d'homonymie") || full_text.include?("page d'homonymie") ||
       full_text.match?(/\A[^\n]{0,50}\s+peut\s+(faire référence|désigner|se référer)/)
      Rails.logger.info "[MiniGPT] Wikipedia page de désambiguïsation détectée : #{page_title}"
      # Suivre le lien le plus pertinent de la page de désambiguïsation
      return follow_disambiguation(lang, page_title, original_query, full_text)
    end

    # Nettoyer le texte Wikipedia (boilerplate)
    clean_text = full_text.gsub(/Sauf indication contraire[^.]*\./, "")
                          .gsub(/==\s*Voir aussi\s*==.*\z/m, "")
                          .gsub(/==\s*Notes et références\s*==.*\z/m, "")
                          .strip

    # Si le texte brut est très court (< 300 chars), l'article utilise probablement des tableaux HTML
    # (fréquent pour les articles "Liste de...", "Classement...")
    if clean_text.length < 300
      Rails.logger.info "[MiniGPT] Texte Wikipedia court (#{clean_text.length} chars), essai extraction tableau HTML"
      table_text = wiki_extract_table(lang, page_title)
      if table_text
        # Combiner l'intro + les données du tableau
        intro_line = clean_text.split("\n").first.to_s.strip
        return "#{intro_line}\n#{table_text}" unless table_text.empty?
      end
    end

    # Chercher la section la plus pertinente selon la question originale
    best_section = find_best_section(clean_text, original_query)

    # Limiter à 2000 caractères, couper à la dernière ligne complète
    if best_section.length > 2000
      best_section = best_section[0..1999]
      last_newline = best_section.rindex("\n")
      best_section = best_section[0..last_newline - 1] if last_newline && last_newline > 100
    end

    best_section.strip.empty? ? nil : best_section
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur wiki_extract #{page_title} : #{e.message}"
    nil
  end

  # Extrait les données d'un tableau HTML d'une page Wikipedia
  # Utilisé quand l'extrait texte brut est trop court (articles de type "Liste de...")
  def wiki_extract_table(lang, page_title)
    encoded = URI.encode_www_form_component(page_title)
    uri = URI("https://#{lang}.wikipedia.org/w/api.php?action=parse&page=#{encoded}&prop=text&redirects=1&format=json")
    response = Net::HTTP.get_response(uri)
    Rails.logger.info "[MiniGPT] wiki_extract_table HTTP #{response.code} pour '#{page_title}'"
    return nil unless response.code == "200"

    data = JSON.parse(response.body)
    html = data.dig("parse", "text", "*")
    if html.nil?
      Rails.logger.info "[MiniGPT] wiki_extract_table: pas de HTML retourné"
      return nil
    end

    Rails.logger.info "[MiniGPT] wiki_extract_table: HTML reçu (#{html.length} chars)"

    # Extraire les lignes du tableau HTML
    rows = []
    html.scan(/<tr[^>]*>(.*?)<\/tr>/m).each do |tr|
      cells = tr[0].scan(/<t[dh][^>]*>(.*?)<\/t[dh]>/m).map do |c|
        c[0].gsub(/<[^>]*>/, "").gsub(/&nbsp;|&#160;/, " ").gsub(/&gt;/, ">").gsub(/&lt;/, "<").gsub(/&amp;/, "&").gsub(/&#91;.*?&#93;/, "").gsub(/\[.*?\]/, "").strip
      end
      row = cells.reject(&:empty?)
      rows << row if row.size >= 2
    end

    Rails.logger.info "[MiniGPT] wiki_extract_table: #{rows.size} lignes de tableau trouvées"
    return nil if rows.empty?

    # Ignorer la ligne d'en-tête, formater les données
    data_rows = rows[1..]
    return nil if data_rows.nil? || data_rows.empty?

    lines = data_rows.first(15).map do |row|
      row.join(" — ")
    end

    result = lines.join("\n")
    Rails.logger.info "[MiniGPT] wiki_extract_table: résultat #{result.length} chars"
    result
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur extraction tableau Wikipedia : #{e.class} #{e.message}"
    Rails.logger.error e.backtrace&.first(3)&.join("\n")
    nil
  end

  # Suit les liens d'une page de désambiguïsation pour trouver l'article principal
  # Utilise le texte de la page pour scorer les descriptions de chaque lien
  def follow_disambiguation(lang, page_title, original_query, disambig_text)
    # Récupérer les liens de la page de désambiguïsation via l'API Wikipedia
    encoded = URI.encode_www_form_component(page_title)
    uri = URI("https://#{lang}.wikipedia.org/w/api.php?action=query&titles=#{encoded}&prop=links&pllimit=30&plnamespace=0&format=json")
    response = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    data = JSON.parse(response.body)
    pages = data.dig("query", "pages")
    return nil if pages.nil?

    links = pages.values.first&.dig("links") || []
    return nil if links.empty?

    link_titles = links.map { |l| l["title"] }.compact

    # Découper le texte de désambiguïsation en lignes pour retrouver la description de chaque lien
    disambig_lines = disambig_text.split("\n").map(&:strip).reject(&:empty?)

    query_keywords = extract_keywords(original_query)
    # Exclure les mots de la page de désambiguïsation du scoring :
    # ils matchent TOUS les liens de la page et ne discriminent pas
    page_words = normalize(page_title)
    discriminating_keywords = query_keywords.reject { |qw| page_words.any? { |pw| stem_match?(qw, pw) } }
    # Si tous les keywords sont le terme de la page, utiliser tous les keywords en fallback
    discriminating_keywords = query_keywords if discriminating_keywords.empty?

    scored = link_titles.map do |title|
      title_lower = title.downcase
      title_words = normalize(title)

      # Trouver TOUTES les lignes de description de ce lien dans le texte de désambiguïsation
      # (un même titre peut apparaître dans plusieurs sections, ex: "Groupe des huit" en formation ET géopolitique)
      matching_lines = disambig_lines.select { |line| line.downcase.include?(title_lower) || title_words.all? { |tw| line.downcase.include?(tw) } }
      desc_words = matching_lines.flat_map { |line| normalize(line) }.uniq

      # Score basé sur la description (les mots discriminants de la question apparaissent dans la description)
      desc_match = discriminating_keywords.count { |qw| desc_words.any? { |dw| stem_match?(qw, dw) } }
      # Score basé sur le titre
      title_match = discriminating_keywords.count { |qw| title_words.any? { |tw| stem_match?(qw, tw) } }
      # Pénaliser les articles trop spécifiques (années, listes de sigles)
      year_penalty = title.match?(/\b(19|20)\d{2}\b/) ? 2 : 0
      list_penalty = title.downcase.start_with?("liste") ? 2 : 0

      score = desc_match * 3 + title_match * 2 - year_penalty - list_penalty
      { title: title, score: score, desc_match: desc_match, title_match: title_match }
    end

    # Trier par score décroissant, exclure les articles sans aucun lien
    scored.sort_by! { |s| [-s[:score], -s[:desc_match]] }
    scored.select! { |s| s[:score] > 0 }

    Rails.logger.info "[MiniGPT] Désambiguïsation #{page_title} : #{scored.first(5).map { |s| "#{s[:title]}(score=#{s[:score]}, desc=#{s[:desc_match]})" }.join(', ')}"

    # Essayer les meilleurs liens (max 3)
    scored.first(3).each do |s|
      Rails.logger.info "[MiniGPT] Désambiguïsation essai : #{s[:title]} (score=#{s[:score]})"
      extract = wiki_extract(lang, s[:title], original_query)
      return extract if extract
    end

    nil
  rescue => e
    Rails.logger.error "[MiniGPT] Erreur follow_disambiguation : #{e.message}"
    nil
  end

  def find_best_section(full_text, query)
    return full_text.split(/\n\n+==/).first.to_s.strip if query.empty?

    # Découper en sections principales (== Titre ==) en gardant les sous-sections (=== ===) avec
    sections = []
    current = ""
    full_text.split("\n").each do |line|
      if line.match?(/\A==\s[^=]/) && !current.empty?
        sections << current.strip
        current = ""
      end
      current += line + "\n"
    end
    sections << current.strip unless current.strip.empty?

    intro = sections.first.to_s.strip
    return intro if sections.size <= 1

    query_words = normalize(query)

    # Trouver l'intention de la question via les mots-clés chargés du YAML
    # Le matching utilise stem_match pour gérer singulier/pluriel automatiquement
    target_keywords = []
    # Ordre de priorité des intentions (les premières sont testées en premier)
    intent_priority = [:cast, :treatment, :cause, :history, :synopsis, :country]

    intent_priority.each do |intent|
      words = @intent_words[intent]
      next if words.nil? || words.empty?
      if query_words.any? { |qw| words.any? { |w| stem_match?(qw, w) } }
        target_keywords = @intent_targets[intent] || []
        break
      end
    end

    if target_keywords.any?
      # 1er passage : chercher dans les titres de section (== Titre ==)
      sections.each do |section|
        first_line = strip_accents(section.split("\n").first.to_s.downcase)
        if target_keywords.any? { |kw| first_line.include?(strip_accents(kw)) }
          # Retirer le header == et les sous-headers === pour ne garder que le contenu
          content = section.split("\n").reject { |l| l.match?(/\A={2,3}\s/) }.join("\n").strip
          return content unless content.empty?
        end
      end

      # 2ème passage : chercher dans les sous-sections (=== Sous-titre ===)
      # Combiner TOUTES les sous-sections qui matchent (ex: toutes les listes de personnages)
      sections.each do |section|
        lines = section.split("\n")
        combined_content = []
        lines.each_with_index do |line, idx|
          next unless line.match?(/\A===/)
          line_lower = strip_accents(line.downcase)
          if target_keywords.any? { |kw| line_lower.include?(strip_accents(kw)) }
            # Extraire le contenu de cette sous-section
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

  def extract_keywords(question)
    stop_words = %w[
      le la les l un une des de du au aux en a y est ce que qui quoi quel quelle quels quelles
      ou où comment pourquoi quand combien estce cest il elle je tu nous vous ils elles on se
      son sa ses mon ma mes ton ta tes notre votre leur leurs sur dans par pour avec sans
      faire fait connais sais dire parle moi dis peux peut donne raconte explique
      jouer joué jouée joues jouent jouait jouaient
      créer creer créé cree crée crees créés créée créées inventer inventé inventée développer developper développé developpe
      trouver trouvé trouve trouves appeler appelé nommer nommé était etait sont été ete avoir être etre
      situer situe situé située situés situées
      connu connue connus connues langage language informatique programmation
      aussi très tres bien plus moins tout tous toute toutes cette cet ces autre autres
      faut falloir prendre donner utiliser comme
      vraiment bon bonne meilleur mieux pire encore même meme
      as ai avons avez ont suis es sommes êtes sera serait
      contre entre chez vers après avant depuis pendant jusque
      si non oui pas ne ni car mais donc or
    ]
    normalize(question).reject { |w| stop_words.include?(w) || w.length < 2 }
  end

  # ----- Apprentissage automatique -----
  def learn_pending(session_id, matched_answer)
    pending = @pending_learns.delete(session_id)
    return if pending.nil? || pending.empty?

    pending.each do |msg|
      next if normalize(msg).empty?
      already_known = @dataset_docs.any? { |d| d["question"] && normalize(d["question"]) == normalize(msg) }
      next if already_known

      pair = { "question" => msg.downcase.strip, "answer" => matched_answer }
      Dataset.create(pair)
      @dataset_docs << pair
      Rails.logger.info "[MiniGPT] Appris : '#{pair['question']}' => '#{pair['answer']}'"
    end
  end

  # ----- Prédiction -----
  def predict(user_message, session_id)
    save_memory(session_id, "user", user_message)

    match = find_best_match(user_message)

    if match
      answer = match["answer"]
      learn_pending(session_id, answer)
    else
      answer = fallback_response(user_message)

      # Sauvegarder les réponses web (sauf météo, car elle change) dans le dataset
      # Ne pas sauvegarder les réponses vides (ex: "D'après Wikipedia : " sans contenu)
      web_prefixes = ["D'après Wikipedia", "D'après DuckDuckGo", "Résultats DuckDuckGo", "Résultats Tavily"]
      has_web_content = web_prefixes.any? { |prefix| answer&.start_with?(prefix) && answer.length > prefix.length + 15 }
      normalized_q = user_message.downcase.strip
      already_saved = @dataset_docs.any? { |d| d["question"] == normalized_q }
      if has_web_content && !already_saved
        # Vérifier que la réponse est pertinente par rapport à la question
        # (au moins un mot-clé de la question doit apparaître dans la réponse)
        question_keywords = extract_keywords(replace_compound_phrases(user_message))
        answer_lower = answer.downcase
        relevant = question_keywords.any? { |kw| answer_lower.include?(kw) }
        if relevant
          pair = { "question" => normalized_q, "answer" => answer }
          Dataset.create(pair)
          @dataset_docs << pair
          Rails.logger.info "[MiniGPT] Appris depuis le web : '#{pair['question']}'"
        else
          Rails.logger.info "[MiniGPT] Réponse web ignorée (non pertinente) pour : '#{normalized_q}'"
          @pending_learns[session_id] ||= []
          @pending_learns[session_id] << user_message
        end
      elsif !answer&.start_with?("Météo à")
        @pending_learns[session_id] ||= []
        @pending_learns[session_id] << user_message
      end
    end

    save_memory(session_id, "bot", answer)
    answer
  end
end
