require "couchrest"

class Dataset
  COUCH_URL = ENV.fetch("COUCHDB_URL", "http://admin:admin@127.0.0.1:5984")
  DB_NAME = "chatgpt_dataset"
  DATASET_PATH = Rails.root.join("config", "dataset.json").to_s

  class << self
    def db
      @db ||= CouchRest.database!("#{COUCH_URL}/#{DB_NAME}")
    end

    # Retourne tous les documents du dataset
    def all
      db.all_docs(include_docs: true)["rows"].map { |r| r["doc"] }
    end

    # Crée un nouveau document dans le dataset
    def create(attrs)
      doc = db.save_doc(attrs)
      attrs.merge("_id" => doc["id"], "_rev" => doc["rev"])
    end

    # Supprime un document du dataset
    def delete(doc)
      db.delete_doc(doc) if doc["_id"] && doc["_rev"]
    end

    # Charge le dataset depuis le fichier JSON si la base est vide
    def seed_if_empty!
      docs = all
      if docs.empty? && File.exist?(DATASET_PATH)
        json_data = JSON.parse(File.read(DATASET_PATH))
        json_data.each { |d| db.save_doc(d) }
        Rails.logger.info "[Dataset] #{json_data.size} entrées importées depuis dataset.json"
        docs = all
      end
      docs
    end

    # Cherche les documents dont la question matche exactement
    def find_by_question(question)
      all.select { |d| d["question"]&.downcase&.strip == question.downcase.strip }
    end
  end
end
