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

  {status: response.status_code, body: response_io.to_s}
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
