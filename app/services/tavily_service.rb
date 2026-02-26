require "net/http"
require "uri"
require "json"

class TavilyService
  def search(query)
    api_key = ENV["TAVILY_API_KEY"]
    return nil if api_key.nil? || api_key.empty?

    keywords = KeywordExtractorService.extract(query)
    return nil if keywords.empty?

    uri              = URI("https://api.tavily.com/search")
    http             = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl     = true
    http.open_timeout = 5
    http.read_timeout = 10

    request                  = Net::HTTP::Post.new(uri)
    request["Content-Type"]  = "application/json"
    request["Authorization"] = "Bearer #{api_key}"
    request.body = {
      query:          keywords.join(" "),
      search_depth:   "basic",
      max_results:    3,
      include_answer: false,
      country:        "France"
    }.to_json

    response = http.request(request)
    return nil unless response.code == "200"

    results = JSON.parse(response.body)["results"]
    return nil if results.nil? || results.empty?

    content = results.first(3).map do |item|
      "#{item['title']} : #{item['content']&.gsub("\n", " ")}"
    end.join("\n")

    SearchResult.from_tavily(content).to_s
  rescue => e
    Rails.logger.error "[TavilyService] Erreur : #{e.message}"
    nil
  end
end
