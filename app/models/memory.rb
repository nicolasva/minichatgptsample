require "couchrest"

class Memory
  COUCH_URL = ENV.fetch("COUCHDB_URL", "http://admin:admin@127.0.0.1:5984")
  DB_NAME = "chatgpt_memory"

  VIEW_BY_SESSION = {
    "_id" => "_design/memory",
    "views" => {
      "by_session" => {
        "map" => "function(doc) { if(doc.session_id) { emit(doc.session_id, { role: doc.role, content: doc.content }); } }"
      }
    }
  }

  class << self
    def db
      @db ||= CouchRest.database!("#{COUCH_URL}/#{DB_NAME}")
    end

    # Crée la vue CouchDB si elle n'existe pas
    def ensure_views!
      existing = db.get("_design/memory") rescue nil
      if existing.nil?
        db.save_doc(VIEW_BY_SESSION)
        Rails.logger.info "[Memory] Vue by_session créée"
      end
    end

    # Retourne les messages d'une session
    def find_by_session(session_id)
      db.view("memory/by_session", key: session_id)["rows"].map { |r| r["value"] }
    rescue => e
      Rails.logger.error "[Memory] Erreur find_by_session : #{e.message}"
      []
    end

    # Sauvegarde un message en mémoire
    def create(session_id:, role:, content:)
      db.save_doc({
        "session_id" => session_id,
        "role" => role,
        "content" => content,
        "timestamp" => Time.now
      })
    end
  end
end
