require "rails_helper"

RSpec.describe ChatGptService do
  include ChatGptServiceHelper

  # ==========================================================================
  # TESTS UNITAIRES — Méthodes pures (pas de CouchDB, pas de réseau)
  # ==========================================================================

  describe "#normalize" do
    subject(:service) { build_bare_service }

    it "met le texte en minuscules" do
      expect(service.normalize("BONJOUR")).to eq(["bonjour"])
    end

    it "supprime la ponctuation" do
      expect(service.normalize("bonjour, comment ça va ?")).to eq(["bonjour", "comment", "ça", "va"])
    end

    it "remplace les apostrophes par des espaces" do
      expect(service.normalize("l'hôpital")).to eq(["l", "hôpital"])
    end

    it "remplace les tirets par des espaces" do
      expect(service.normalize("saint-malo")).to eq(["saint", "malo"])
    end

    it "conserve les caractères accentués" do
      expect(service.normalize("éléphant")).to eq(["éléphant"])
    end

    it "conserve les chiffres" do
      expect(service.normalize("g8 g20")).to eq(["g8", "g20"])
    end

    it "retourne un tableau vide pour une chaîne vide" do
      expect(service.normalize("")).to eq([])
    end

    it "gère les espaces multiples" do
      expect(service.normalize("  bonjour   monde  ")).to eq(["bonjour", "monde"])
    end

    it "gère les apostrophes typographiques" do
      expect(service.normalize("l\u2019école")).to eq(["l", "école"])
    end
  end

  # ==========================================================================
  describe "#strip_accents" do
    subject(:service) { build_bare_service }

    it "supprime les accents aigus" do
      expect(service.strip_accents("éléphant")).to eq("elephant")
    end

    it "supprime les accents graves" do
      expect(service.strip_accents("père")).to eq("pere")
    end

    it "supprime les accents circonflexes" do
      expect(service.strip_accents("hôpital")).to eq("hopital")
    end

    it "supprime les trémas" do
      expect(service.strip_accents("naïf")).to eq("naif")
    end

    it "supprime les cédilles" do
      expect(service.strip_accents("français")).to eq("francais")
    end

    it "ne modifie pas les caractères sans accent" do
      expect(service.strip_accents("bonjour")).to eq("bonjour")
    end

    it "gère une combinaison d'accents" do
      expect(service.strip_accents("àéîôùç")).to eq("aeiouc")
    end
  end

  # ==========================================================================
  describe "#stem_match?" do
    subject(:service) { build_bare_service }

    it "matche les mots identiques" do
      expect(service.stem_match?("chat", "chat")).to be true
    end

    it "matche indépendamment des accents" do
      expect(service.stem_match?("éléphant", "elephant")).to be true
    end

    it "matche le pluriel en -s" do
      expect(service.stem_match?("chat", "chats")).to be true
    end

    it "matche le pluriel en -es" do
      expect(service.stem_match?("maison", "maisons")).to be true
    end

    it "matche le pluriel en -x" do
      expect(service.stem_match?("château", "châteaux")).to be true
    end

    it "matche -aux / -al (national/nationaux)" do
      expect(service.stem_match?("national", "nationaux")).to be true
    end

    it "matche les terminaisons verbales joué/jouer" do
      expect(service.stem_match?("joué", "jouer")).to be true
    end

    it "matche les terminaisons verbales joué/joue" do
      expect(service.stem_match?("joué", "joue")).to be true
    end

    it "matche les terminaisons verbales jouée/jouer" do
      expect(service.stem_match?("jouée", "jouer")).to be true
    end

    it "matche visiter/visité" do
      expect(service.stem_match?("visiter", "visité")).to be true
    end

    it "ne matche pas les mots complètement différents" do
      expect(service.stem_match?("chat", "chien")).to be false
    end

    it "ne matche pas les stems trop courts" do
      expect(service.stem_match?("as", "ant")).to be false
    end

    it "matche continent/continents" do
      expect(service.stem_match?("continent", "continents")).to be true
    end
  end

  # ==========================================================================
  describe "#jaccard_similarity" do
    subject(:service) { build_bare_service }

    it "retourne 1.0 pour des tableaux identiques" do
      expect(service.jaccard_similarity(%w[a b c], %w[a b c])).to eq(1.0)
    end

    it "retourne 0.0 pour des tableaux disjoints" do
      expect(service.jaccard_similarity(%w[a b], %w[c d])).to eq(0.0)
    end

    it "retourne 0.0 pour un tableau vide" do
      expect(service.jaccard_similarity([], %w[a b])).to eq(0.0)
    end

    it "retourne 0.0 pour deux tableaux vides" do
      expect(service.jaccard_similarity([], [])).to eq(0.0)
    end

    it "calcule correctement pour un cas réel" do
      words_a = %w[salut comment ca va]
      words_b = %w[bonjour comment ca va]
      # intersection = {comment, ca, va} = 3, union = {salut, bonjour, comment, ca, va} = 5
      expect(service.jaccard_similarity(words_a, words_b)).to eq(0.6)
    end

    it "retourne 0.5 pour une intersection de moitié" do
      # {a,b,c,d} & {a,b,e,f} => intersection=2, union=6 => 2/6 = 0.333
      expect(service.jaccard_similarity(%w[a b c d], %w[a b e f])).to be_within(0.01).of(0.333)
    end
  end

  # ==========================================================================
  describe "#extract_keywords" do
    subject(:service) { build_bare_service }

    it "supprime les articles et prépositions" do
      result = service.extract_keywords("le chat de la maison")
      expect(result).to include("chat", "maison")
      expect(result).not_to include("le", "de", "la")
    end

    it "supprime les mots interrogatifs" do
      result = service.extract_keywords("qui a inventé le téléphone")
      expect(result).to include("téléphone")
      expect(result).not_to include("qui")
    end

    it "garde les mots significatifs pour 'mission impossible'" do
      result = service.extract_keywords("qui a joué dans mission impossible")
      expect(result).to include("mission", "impossible")
      expect(result).not_to include("qui", "dans", "joué")
    end

    it "garde les mots significatifs pour un pays" do
      result = service.extract_keywords("quel est le pays le plus visité dans le monde")
      expect(result).to include("visité", "monde")
      expect(result).not_to include("quel", "est", "le", "dans")
    end

    it "retourne un tableau vide pour une phrase de stop words" do
      result = service.extract_keywords("qui est ce que tu es")
      expect(result).to be_empty
    end

    it "supprime les mots de moins de 2 caractères" do
      result = service.extract_keywords("a y va")
      result.each { |w| expect(w.length).to be >= 2 }
    end

    it "garde les noms propres en minuscules" do
      result = service.extract_keywords("qui est Napoleon Bonaparte")
      expect(result).to include("napoleon", "bonaparte")
    end

    it "garde les acronymes" do
      result = service.extract_keywords("quels pays composent le g8")
      expect(result).to include("g8")
    end

    it "supprime les verbes de création" do
      result = service.extract_keywords("qui a créé Python")
      expect(result).to include("python")
      expect(result).not_to include("créé")
    end
  end

  # ==========================================================================
  describe "#normalize_for_matching" do
    subject(:service) { build_bare_service }

    it "filtre les stop words du matching" do
      result = service.normalize_for_matching("je suis un développeur")
      expect(result).not_to include("je", "un")
      expect(result).to include("développeur")
    end

    it "filtre les mots courts" do
      result = service.normalize_for_matching("a b cd efg")
      expect(result).not_to include("a", "b")
    end

    it "garde les mots significatifs d'une question" do
      result = service.normalize_for_matching("quel est le sens de la vie")
      expect(result).to include("sens", "vie")
    end
  end

  # ==========================================================================
  describe "#opinion_question?" do
    subject(:service) { build_bare_service }

    it "détecte 'est-ce que la ville est belle'" do
      expect(service.opinion_question?("est-ce que la ville est belle ?")).to be true
    end

    it "détecte 'tu trouves ça bien'" do
      expect(service.opinion_question?("tu trouves ça bien ?")).to be true
    end

    it "détecte 'c est joli' (avec espace)" do
      expect(service.opinion_question?("c est joli ?")).to be true
    end

    it "détecte 'tu penses que c'est facile'" do
      expect(service.opinion_question?("tu penses que c'est facile ?")).to be true
    end

    it "détecte 'tu crois que c'est vrai'" do
      expect(service.opinion_question?("tu crois que c'est vrai ?")).to be true
    end

    it "ne détecte pas une question factuelle" do
      expect(service.opinion_question?("qui a inventé le téléphone ?")).to be false
    end

    it "ne détecte pas un pattern d'opinion sans adjectif subjectif" do
      expect(service.opinion_question?("est-ce que tu manges ?")).to be false
    end

    it "ne détecte pas une question simple" do
      expect(service.opinion_question?("comment ça marche ?")).to be false
    end
  end

  # ==========================================================================
  describe "#extract_relevant?" do
    subject(:service) { build_bare_service }

    it "retourne true pour une requête vide" do
      expect(service.extract_relevant?("some extract", "")).to be true
    end

    it "retourne true pour une requête nil" do
      expect(service.extract_relevant?("some extract", nil)).to be true
    end

    it "retourne true pour une requête avec un seul mot-clé" do
      expect(service.extract_relevant?("Tom Cruise est un acteur", "acteur")).to be true
    end

    it "retourne true quand la première phrase contient les mots-clés" do
      extract = "La France est le pays le plus visité au monde. Chaque année, des millions de touristes..."
      query = "quel est le pays le plus visité"
      expect(service.extract_relevant?(extract, query)).to be true
    end

    it "retourne false quand la première phrase ne correspond pas" do
      extract = "Le Grand Continent est une revue européenne. Elle publie des articles sur la géopolitique."
      query = "quel est le continent le plus visité"
      expect(service.extract_relevant?(extract, query)).to be false
    end

    it "rejette les faux positifs comme Benoît XVI pour 'continent visité'" do
      extract = "Au cours de son pontificat, Benoît XVI a effectué 25 visites pastorales hors d'Italie."
      query = "quel est le continent le plus visité"
      expect(service.extract_relevant?(extract, query)).to be false
    end

    it "accepte un extrait pertinent sur le tourisme" do
      extract = "Le tourisme en France est un secteur économique majeur du pays visité par 90 millions de touristes."
      query = "pays le plus visité"
      expect(service.extract_relevant?(extract, query)).to be true
    end
  end

  # ==========================================================================
  describe "#is_question?" do
    subject(:service) { build_bare_service }

    it "détecte un point d'interrogation" do
      expect(service.is_question?("tu vas bien ?")).to be true
    end

    it "détecte un mot interrogatif (qui)" do
      expect(service.is_question?("qui est le président")).to be true
    end

    it "détecte un mot interrogatif (comment)" do
      expect(service.is_question?("comment ça marche")).to be true
    end

    it "détecte un mot interrogatif (où)" do
      expect(service.is_question?("où est la gare")).to be true
    end

    it "détecte un mot interrogatif (pourquoi)" do
      expect(service.is_question?("pourquoi le ciel est bleu")).to be true
    end

    it "ne détecte pas une affirmation" do
      expect(service.is_question?("je suis content")).to be false
    end

    it "ne détecte pas un salut" do
      expect(service.is_question?("bonjour")).to be false
    end
  end

  # ==========================================================================
  describe "#levenshtein_close?" do
    subject(:service) { build_bare_service }

    it "retourne true pour des mots identiques" do
      expect(service.levenshtein_close?("test", "test")).to be true
    end

    it "retourne true pour des mots proches" do
      expect(service.levenshtein_close?("test", "tast")).to be true
    end

    it "retourne false pour des mots trop différents en longueur" do
      expect(service.levenshtein_close?("ab", "abcdef")).to be false
    end

    it "retourne false pour des mots complètement différents" do
      expect(service.levenshtein_close?("abcd", "wxyz")).to be false
    end
  end

  # ==========================================================================
  # TESTS AVEC DATASET (chargé depuis JSON, pas de CouchDB)
  # ==========================================================================

  describe "#find_best_match" do
    subject(:service) { build_service_with_dataset }

    context "match exact" do
      it "trouve 'bonjour'" do
        match = service.find_best_match("bonjour")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Salut, comment ça va ?")
      end

      it "trouve 'salut'" do
        match = service.find_best_match("salut")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Salut !")
      end

      it "trouve 'merci'" do
        match = service.find_best_match("merci")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("De rien, avec plaisir !")
      end

      it "trouve 'au revoir'" do
        match = service.find_best_match("au revoir")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Au revoir ! À bientôt !")
      end

      it "trouve 'bye'" do
        match = service.find_best_match("bye")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Bye bye ! Reviens quand tu veux !")
      end

      it "trouve 'quel est le sens de la vie'" do
        match = service.find_best_match("quel est le sens de la vie")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("42, évidemment !")
      end

      it "trouve 'qui es-tu'" do
        match = service.find_best_match("qui es-tu")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Je suis un simple logiciel, écrit pour répéter ce qu'on m'a appris.")
      end

      it "trouve 'raconte-moi une blague'" do
        match = service.find_best_match("raconte-moi une blague")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("plongeurs")
      end

      it "trouve 'lol'" do
        match = service.find_best_match("lol")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Haha content de te faire rire !")
      end

      it "trouve 'je suis triste'" do
        match = service.find_best_match("je suis triste")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("Dis-moi ce qui ne va pas")
      end

      it "trouve 'je suis content'" do
        match = service.find_best_match("je suis content")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("plaisir")
      end

      it "trouve 'comment tu t'appelles'" do
        match = service.find_best_match("comment tu t'appelles")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("MiniGPT")
      end

      it "trouve 'quel est ton age'" do
        match = service.find_best_match("quel est ton age")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("jeune")
      end

      it "trouve 'hello'" do
        match = service.find_best_match("hello")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Hello ! How can I help you ?")
      end

      it "trouve 'bonsoir'" do
        match = service.find_best_match("bonsoir")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("Bonsoir")
      end

      it "trouve 'bonne nuit'" do
        match = service.find_best_match("bonne nuit")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("rêves")
      end
    end

    context "réponses multiples (random)" do
      it "retourne une des réponses possibles pour 'salut comment ca va'" do
        match = service.find_best_match("salut comment ca va")
        expect(match).not_to be_nil
        expect(["Bien, merci !", "Très bien, merci"]).to include(match["answer"])
      end

      it "retourne une des réponses possibles pour 'bonjour comment ca va'" do
        match = service.find_best_match("bonjour comment ca va")
        expect(match).not_to be_nil
        expect(["Okay", "Génial", "Ça pourrait aller mieux", "Comme ci, comme ça"]).to include(match["answer"])
      end

      it "retourne une des réponses possibles pour 'quoi de neuf'" do
        match = service.find_best_match("quoi de neuf")
        expect(match).not_to be_nil
        possible = ["Rien de nouveau, et toi ?", "Tout baigne !", "Le chiffre avant 10, sinon, toi, quoi de neuf ?"]
        expect(possible).to include(match["answer"])
      end

      it "retourne une des réponses pour 'comment vas-tu'" do
        match = service.find_best_match("comment vas-tu")
        expect(match).not_to be_nil
        possible = ["Je vais bien, et vous ?", "Je vais bien, et toi ?"]
        expect(possible).to include(match["answer"])
      end
    end

    context "matching Jaccard" do
      it "matche 'qui es tu' (sans tiret) avec 'qui es-tu'" do
        match = service.find_best_match("qui es tu")
        expect(match).not_to be_nil
      end

      it "matche 'ca va' avec 'ca va'" do
        match = service.find_best_match("ca va")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("merci")
      end
    end

    context "vie du robot" do
      it "trouve 'bois-tu'" do
        match = service.find_best_match("bois-tu")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("boisson")
      end

      it "trouve 'est-ce que tu bois'" do
        match = service.find_best_match("est-ce que tu bois")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("boisson")
      end

      it "trouve 'un robot peut-il etre saoul'" do
        match = service.find_best_match("un robot peut-il etre saoul")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("pompette")
      end

      it "trouve 'peux-tu faire du mal a un humain'" do
        match = service.find_best_match("peux-tu faire du mal a un humain")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("première loi")
      end

      it "trouve 'parle-moi de toi'" do
        match = service.find_best_match("parle-moi de toi")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("MiniGPT")
      end

      it "trouve 'où te trouves-tu'" do
        match = service.find_best_match("où te trouves-tu")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Partout !")
      end

      it "trouve 'quelle est ton adresse'" do
        match = service.find_best_match("quelle est ton adresse")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("Internet")
      end

      it "trouve 'où es-tu'" do
        match = service.find_best_match("où es-tu")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("Internet")
      end

      it "trouve 'quel est ton numero'" do
        match = service.find_best_match("quel est ton numero")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Je n'ai pas de numéro.")
      end

      it "trouve 'pourquoi ne manges-tu pas de nourriture'" do
        match = service.find_best_match("pourquoi ne manges-tu pas de nourriture")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("programme informatique")
      end

      it "trouve 'qui est ton patron'" do
        match = service.find_best_match("qui est ton patron")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("auto-entrepreneur")
      end

      it "trouve 'quel age as-tu'" do
        match = service.find_best_match("quel age as-tu")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("jeune")
      end
    end

    context "variantes de salutations" do
      it "retourne une des réponses pour 'salut comment vas-tu'" do
        match = service.find_best_match("salut comment vas-tu")
        expect(match).not_to be_nil
      end

      it "retourne une des réponses pour 'bonjour comment vas-tu'" do
        match = service.find_best_match("bonjour comment vas-tu")
        expect(match).not_to be_nil
        possible = ["Okay", "Génial !", "Je vais bien merci, et toi ?"]
        expect(possible).to include(match["answer"])
      end

      it "trouve 'ca va'" do
        match = service.find_best_match("ca va")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("merci")
      end

      it "trouve 'bonjour ca va'" do
        match = service.find_best_match("bonjour ca va")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("merci")
      end

      it "trouve 'salut ca va'" do
        match = service.find_best_match("salut ca va")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("merci")
      end
    end

    context "projets et langages" do
      it "trouve 'je travaille sur un projet'" do
        match = service.find_best_match("je travaille sur un projet")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("travailles")
      end

      it "trouve 'quels langages utilises-tu'" do
        match = service.find_best_match("quels langages utilises-tu")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("Ruby")
      end

      it "trouve 'que signifie yolo'" do
        match = service.find_best_match("que signifie yolo")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("vivrais")
      end

      it "trouve 'quels sont tes sujets preferes'" do
        match = service.find_best_match("quels sont tes sujets preferes")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("robotique")
      end
    end

    context "questions pratiques" do
      it "trouve 'quel jour sommes-nous'" do
        match = service.find_best_match("quel jour sommes-nous")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("calendrier")
      end

      it "trouve 'quelle heure est-il'" do
        match = service.find_best_match("quelle heure est-il")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("montre")
      end

      it "trouve 'qu'est ce qui te derange'" do
        match = service.find_best_match("qu'est ce qui te derange")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("chiffres")
      end

      it "trouve 'quel temps fait-il'" do
        match = service.find_best_match("quel temps fait-il")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("météo")
      end

      it "trouve 'j'ai besoin d'aide'" do
        match = service.find_best_match("j'ai besoin d'aide")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("aider")
      end

      it "trouve 'es-tu la'" do
        match = service.find_best_match("es-tu la")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("là")
      end
    end

    context "réponses courtes manquantes" do
      it "trouve 'pourquoi'" do
        match = service.find_best_match("pourquoi")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("Bonne question")
      end

      it "trouve 'comment'" do
        match = service.find_best_match("comment")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("préciser")
      end

      it "trouve 'quand'" do
        match = service.find_best_match("quand")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("contexte")
      end

      it "trouve 'bien'" do
        match = service.find_best_match("bien")
        expect(match).not_to be_nil
        expect(match["answer"]).to eq("Super !")
      end

      it "trouve 'pas bien'" do
        match = service.find_best_match("pas bien")
        expect(match).not_to be_nil
        expect(match["answer"]).to include("ne va pas")
      end
    end

    context "cohérence des réponses" do
      it "une salutation donne une réponse contenant un mot de salutation" do
        greetings = %w[bonjour salut coucou hey hello bonsoir]
        greetings.each do |greeting|
          match = service.find_best_match(greeting)
          expect(match).not_to be_nil, "Pas de match pour '#{greeting}'"
          answer = match["answer"].downcase
          expect(answer).to satisfy("contenir un mot de salutation pour '#{greeting}'") { |a|
            a.include?("salut") || a.include?("bonjour") || a.include?("coucou") ||
            a.include?("hey") || a.include?("hello") || a.include?("bonsoir") ||
            a.include?("plaisir") || a.include?("comment")
          }
        end
      end

      it "un au revoir donne une réponse de départ" do
        goodbyes = ["au revoir", "bye", "à plus", "bonne nuit", "bonne journée"]
        goodbyes.each do |goodbye|
          match = service.find_best_match(goodbye)
          expect(match).not_to be_nil, "Pas de match pour '#{goodbye}'"
          answer = match["answer"].downcase
          expect(answer).to satisfy("contenir un mot de départ pour '#{goodbye}'") { |a|
            a.include?("revoir") || a.include?("bientôt") || a.include?("bye") ||
            a.include?("nuit") || a.include?("rêves") || a.include?("journée") ||
            a.include?("merci") || a.include?("reviens")
          }
        end
      end

      it "les questions d'identité mentionnent le bot ou ses caractéristiques" do
        identity_qs = ["qui es-tu", "comment tu t'appelles", "c'est quoi ton nom", "tu es un robot", "es-tu humain"]
        identity_qs.each do |q|
          match = service.find_best_match(q)
          expect(match).not_to be_nil, "Pas de match pour '#{q}'"
          answer = match["answer"].downcase
          expect(answer).to satisfy("mentionner le bot pour '#{q}'") { |a|
            a.include?("minigpt") || a.include?("chatbot") || a.include?("logiciel") ||
            a.include?("programme") || a.include?("ruby")
          }
        end
      end

      it "les émotions reçoivent une réponse empathique" do
        emotions = {
          "je suis triste" => %w[dis-moi là pour],
          "je suis content" => %w[super plaisir],
          "je m'ennuie" => %w[discuter question],
          "je suis fatigué" => %w[repose santé]
        }
        emotions.each do |msg, keywords|
          match = service.find_best_match(msg)
          expect(match).not_to be_nil, "Pas de match pour '#{msg}'"
          answer = match["answer"].downcase
          expect(answer).to satisfy("contenir un mot empathique pour '#{msg}'") { |a|
            keywords.any? { |kw| a.include?(kw) }
          }
        end
      end

      it "les compliments reçoivent un remerciement" do
        compliments = ["tu es gentil", "tu es drôle", "tu es intelligent"]
        compliments.each do |c|
          match = service.find_best_match(c)
          expect(match).not_to be_nil, "Pas de match pour '#{c}'"
          answer = match["answer"].downcase
          expect(answer).to satisfy("contenir un remerciement pour '#{c}'") { |a|
            a.include?("merci") || a.include?("mieux")
          }
        end
      end

      it "les insultes reçoivent une réponse calme" do
        insults = ["t'es nul", "tu es bête"]
        insults.each do |i|
          match = service.find_best_match(i)
          expect(match).not_to be_nil, "Pas de match pour '#{i}'"
          answer = match["answer"].downcase
          expect(answer).to satisfy("contenir une réponse calme pour '#{i}'") { |a|
            a.include?("désolé") || a.include?("apprentissage") || a.include?("patient")
          }
        end
      end
    end

    context "aucun match" do
      it "retourne nil pour une question inconnue" do
        match = service.find_best_match("quelle est la masse de Jupiter")
        expect(match).to be_nil
      end

      it "retourne nil pour du charabia" do
        match = service.find_best_match("xyzzy plugh abracadabra")
        expect(match).to be_nil
      end

      it "retourne nil pour une question spécialisée" do
        match = service.find_best_match("comment fonctionne la photosynthèse")
        expect(match).to be_nil
      end
    end
  end

  # ==========================================================================
  # TESTS FALLBACK (avec stubs pour éviter le réseau)
  # ==========================================================================

  describe "#fallback_response" do
    subject(:service) { build_bare_service }

    context "sentiment positif" do
      it "retourne une réponse positive pour 'tout est super génial'" do
        allow(service).to receive(:search_weather).and_return(nil)
        response = service.fallback_response("tout est super génial")
        expect(ChatGptService::POSITIVE_RESPONSES).to include(response)
      end

      it "retourne une réponse positive pour 'c'est formidable'" do
        allow(service).to receive(:search_weather).and_return(nil)
        response = service.fallback_response("c'est formidable")
        expect(ChatGptService::POSITIVE_RESPONSES).to include(response)
      end
    end

    context "sentiment négatif" do
      it "retourne une réponse négative pour 'tout est horrible'" do
        allow(service).to receive(:search_weather).and_return(nil)
        response = service.fallback_response("tout est horrible et nul")
        expect(ChatGptService::NEGATIVE_RESPONSES).to include(response)
      end

      it "retourne une réponse négative pour 'j'ai peur'" do
        allow(service).to receive(:search_weather).and_return(nil)
        response = service.fallback_response("j'ai peur de l'orage")
        expect(ChatGptService::NEGATIVE_RESPONSES).to include(response)
      end
    end

    context "message neutre" do
      it "retourne une réponse par défaut pour du texte neutre" do
        allow(service).to receive(:search_weather).and_return(nil)
        response = service.fallback_response("patate")
        expect(ChatGptService::DEFAULT_RESPONSES).to include(response)
      end
    end

    context "question factuelle" do
      it "lance une recherche web pour une question" do
        allow(service).to receive(:search_weather).and_return(nil)
        allow(service).to receive(:search_web).and_return("D'après Wikipedia : résultat")
        response = service.fallback_response("qui a inventé le téléphone")
        expect(response).to eq("D'après Wikipedia : résultat")
      end

      it "retourne une réponse générique si la recherche échoue" do
        allow(service).to receive(:search_weather).and_return(nil)
        allow(service).to receive(:search_web).and_return(nil)
        response = service.fallback_response("qui a inventé le téléphone")
        expect(ChatGptService::QUESTION_RESPONSES).to include(response)
      end
    end

    context "question d'opinion" do
      it "ne lance pas de recherche web pour une question d'opinion" do
        allow(service).to receive(:search_weather).and_return(nil)
        expect(service).not_to receive(:search_web)
        response = service.fallback_response("est-ce que Paris est belle ?")
        expect(ChatGptService::QUESTION_RESPONSES).to include(response)
      end
    end

    context "météo" do
      it "retourne la météo quand détectée" do
        allow(service).to receive(:search_weather).with("quel temps fait-il à Paris").and_return(
          "Météo à Paris : Ensoleillé, 22°C (ressenti 24°C), humidité 45%."
        )
        response = service.fallback_response("quel temps fait-il à Paris")
        expect(response).to start_with("Météo à Paris")
      end
    end
  end

  # ==========================================================================
  describe "#extract_city" do
    subject(:service) { build_bare_service }

    it "extrait la ville après 'à'" do
      expect(service.extract_city("quel temps fait-il à Paris")).to eq("paris")
    end

    it "extrait une ville composée" do
      expect(service.extract_city("météo à new york")).to eq("new york")
    end

    it "extrait la ville après 'au'" do
      expect(service.extract_city("quel temps au havre")).to eq("havre")
    end

    it "extrait la ville après 'en'" do
      expect(service.extract_city("quel temps en bretagne")).to eq("bretagne")
    end

    it "retourne nil sans préposition de lieu" do
      expect(service.extract_city("quel temps fait-il")).to be_nil
    end
  end

  # ==========================================================================
  # TESTS D'INTÉGRATION — Avec CouchDB (predict)
  # ==========================================================================

  describe "#predict (intégration CouchDB)" do
    let(:service) { ChatGptService.new }
    let(:session_id) { "rspec-#{SecureRandom.hex(4)}" }

    context "questions du dataset" do
      it "retourne 'Salut, comment ça va ?' pour 'bonjour'" do
        response = service.predict("bonjour", session_id)
        expect(response).to eq("Salut, comment ça va ?")
      end

      it "retourne 'Salut !' pour 'salut'" do
        response = service.predict("salut", session_id)
        expect(response).to eq("Salut !")
      end

      it "retourne une réponse cohérente pour 'merci'" do
        response = service.predict("merci", session_id)
        expect(response).to be_a(String)
        expect(response).not_to be_empty
      end

      it "retourne '42, évidemment !' pour 'quel est le sens de la vie'" do
        response = service.predict("quel est le sens de la vie", session_id)
        expect(response).to eq("42, évidemment !")
      end

      it "retourne une blague pour 'raconte-moi une blague'" do
        response = service.predict("raconte-moi une blague", session_id)
        expect(response).to include("plongeurs")
      end

      it "retourne l'identité pour 'qui es-tu'" do
        response = service.predict("qui es-tu", session_id)
        expect(response).to include("logiciel")
      end

      it "retourne une réponse pour 'hello'" do
        response = service.predict("hello", session_id)
        expect(response).to eq("Hello ! How can I help you ?")
      end

      it "retourne une réponse pour 'au revoir'" do
        response = service.predict("au revoir", session_id)
        expect(response).to eq("Au revoir ! À bientôt !")
      end
    end

    context "mémoire" do
      it "sauvegarde les messages en mémoire" do
        service.predict("bonjour", session_id)
        memory = Memory.find_by_session(session_id)
        expect(memory.size).to eq(2)
        roles = memory.map { |m| m["role"] }
        expect(roles).to include("user", "bot")
      end
    end
  end

  # ==========================================================================
  # TESTS API EXTERNES (lents, tagués :slow)
  # ==========================================================================

  describe "#predict (recherche web)", :slow do
    let(:service) { ChatGptService.new }
    let(:session_id) { "rspec-slow-#{SecureRandom.hex(4)}" }

    it "trouve Tom Cruise pour 'qui a joué dans mission impossible'" do
      response = service.predict("qui a joué dans mission impossible", session_id)
      expect(response).to include("Tom Cruise")
    end

    it "trouve des données sur les pays les plus visités" do
      response = service.predict("quel est le pays le plus visité dans le monde", session_id)
      expect(response.downcase).to satisfy("contenir France ou pays ou visité") { |r|
        r.include?("france") || r.include?("pays") || r.include?("visité")
      }
    end

    it "retourne des informations Wikipedia pour 'quels pays composent le g8'" do
      response = service.predict("quels pays composent le g8", session_id)
      expect(response).to include("Wikipedia").or include("G7").or include("G8")
    end

    it "retourne la météo pour 'quel temps fait-il à Paris'" do
      response = service.predict("quel temps fait-il à Paris", session_id)
      expect(response).to start_with("Météo à")
    end

    it "retourne des infos sur le Titanic pour 'qui a joué dans Titanic'" do
      response = service.predict("qui a joué dans Titanic", session_id)
      expect(response.downcase).to satisfy("contenir DiCaprio ou Kate") { |r|
        r.include?("dicaprio") || r.include?("kate") || r.include?("winslet") || r.include?("cameron")
      }
    end

    it "retourne des infos pour 'où se trouve Erquy'" do
      response = service.predict("où se trouve Erquy", session_id)
      expect(response).to include("Wikipedia")
    end
  end
end
