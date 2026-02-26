require "net/http"
require "uri"
require "json"

class WeatherService
  WEATHER_WORDS     = %w[temps météo meteo température temperature climat pluie soleil neige vent chaud froid].freeze
  QUESTION_WORDS    = %w[qui que quoi quel quelle quels quelles où comment pourquoi quand combien est-ce].freeze
  CITY_PREPOSITIONS = %w[à a au en sur].freeze

  def search(message)
    city         = extract_city(message)
    city         = "Paris" if city.nil? || city.empty?
    encoded_city = URI.encode_www_form_component(city)

    uri      = URI("https://wttr.in/#{encoded_city}?format=j1&lang=fr")
    response = Net::HTTP.get_response(uri)
    return nil unless response.code == "200"

    current = JSON.parse(response.body)["current_condition"]&.first
    return nil unless current

    temp        = current["temp_C"]
    feels_like  = current["FeelsLikeC"]
    humidity    = current["humidity"]
    description = current.dig("lang_fr", 0, "value") || current.dig("weatherDesc", 0, "value")

    "Météo à #{city.capitalize} : #{description}, #{temp}°C (ressenti #{feels_like}°C), humidité #{humidity}%."
  rescue => e
    Rails.logger.error "[WeatherService] Erreur : #{e.message}"
    nil
  end

  def extract_city(message)
    words = message.downcase.gsub(/[?!.,]/, "").split
    words.each_with_index do |w, i|
      next unless CITY_PREPOSITIONS.include?(w) && words[i + 1]
      city_parts = []
      (i + 1...words.size).each do |j|
        break if WEATHER_WORDS.include?(words[j]) || QUESTION_WORDS.include?(words[j]) || %w[aujourd'hui demain ce cette].include?(words[j])
        city_parts << words[j]
      end
      return city_parts.join(" ") if city_parts.any?
    end
    nil
  end
end
