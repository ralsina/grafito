require "spec"
require "webmock"
require "../src/grafito"

# Dispatches an HTTP request through Kemal's route handler without binding
# a socket. Returns the response status code and body.
# Routes must be registered exactly once: Kemal raises when the same
# route path is added twice.
Grafito.register_routes

def dispatch_request(method : String, path : String, body : String? = nil, headers : HTTP::Headers = HTTP::Headers.new)
  io = IO::Memory.new(body.to_s)
  request = HTTP::Request.new(method, path, headers, io)
  response_io = IO::Memory.new
  response = HTTP::Server::Response.new(response_io)
  context = HTTP::Server::Context.new(request, response)

  Kemal::RouteHandler::INSTANCE.call(context)
  response.close

  # Depending on how the route writes its response, the raw IO may
  # contain the full HTTP head. Strip it so specs see just the body;
  # keep the headers either way (e.g. for content-type assertions).
  raw_body = response_io.to_s
  body_text, response_headers = if raw_body.starts_with?("HTTP/")
                                  head, _, rest = raw_body.partition("\r\n\r\n")
                                  parsed = HTTP::Headers.new
                                  head.each_line.skip(1).each do |line|
                                    name, _, value = line.partition(":")
                                    parsed.add(name.strip, value.strip)
                                  end
                                  {rest || "", parsed}
                                else
                                  {raw_body, response.headers}
                                end

  {status: response.status_code, body: body_text, headers: response_headers}
end

# Minimal AI provider used to enable AI-dependent UI in specs.
class FakeAIProvider < Grafito::AI::Provider
  def name : String
    "fake"
  end

  def complete(request : Grafito::AI::Request) : Grafito::AI::Response
    Grafito::AI::Response.new(content: "fake explanation", model: "fake-model", provider: "fake")
  end

  def available? : Bool
    true
  end

  def models : Array(Grafito::AI::ModelInfo)
    [] of Grafito::AI::ModelInfo
  end

  def current_model : String
    "fake-model"
  end
end
