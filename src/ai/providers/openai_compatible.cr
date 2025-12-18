# src/ai/providers/openai_compatible.cr
#
# Provider for OpenAI-compatible APIs.
#
# Supports multiple backends that implement the OpenAI chat completions API:
# - Z.AI (default, backward compatible)
# - OpenAI
# - Groq
# - Together.ai
# - Ollama (local)
# - Any other OpenAI-compatible API

require "http/client"
require "json"
require "uri"
require "../provider"
require "../request"
require "../response"

module Grafito::AI::Providers
  # Provider for OpenAI-compatible APIs.
  #
  # Configuration:
  # - Z_AI_API_KEY / OPENAI_API_KEY / GROQ_API_KEY / etc: API key
  # - GRAFITO_AI_API_KEY: Generic API key fallback
  # - GRAFITO_AI_MODEL: Model override
  # - GRAFITO_AI_ENDPOINT: Custom endpoint URL
  class OpenAICompatible < Provider
    Log = ::Log.for(self)

    # Known provider configurations
    record ProviderConfig,
      endpoint : String,
      default_model : String,
      env_key : String?,
      name : String

    PROVIDERS = {
      "z_ai" => ProviderConfig.new(
        endpoint: "https://api.z.ai/api/paas/v4/chat/completions",
        default_model: "glm-4.5-flash",
        env_key: "Z_AI_API_KEY",
        name: "Z.AI"
      ),
      "openai" => ProviderConfig.new(
        endpoint: "https://api.openai.com/v1/chat/completions",
        default_model: "gpt-4o-mini",
        env_key: "OPENAI_API_KEY",
        name: "OpenAI"
      ),
      "groq" => ProviderConfig.new(
        endpoint: "https://api.groq.com/openai/v1/chat/completions",
        default_model: "llama-3.1-70b-versatile",
        env_key: "GROQ_API_KEY",
        name: "Groq"
      ),
      "together" => ProviderConfig.new(
        endpoint: "https://api.together.xyz/v1/chat/completions",
        default_model: "meta-llama/Llama-3-70b-chat-hf",
        env_key: "TOGETHER_API_KEY",
        name: "Together.ai"
      ),
      "ollama" => ProviderConfig.new(
        endpoint: "http://localhost:11434/v1/chat/completions",
        default_model: "llama3",
        env_key: nil, # Ollama doesn't require API key
        name: "Ollama"
      ),
    }

    @api_key : String
    @endpoint : URI
    @model : String
    @provider_name : String
    @timeout : Time::Span

    def initialize(force_provider : String? = nil)
      provider_id = force_provider || detect_provider
      config = PROVIDERS[provider_id]? || PROVIDERS["z_ai"]

      @provider_name = config.name
      @api_key = resolve_api_key(config)
      @endpoint = URI.parse(ENV["GRAFITO_AI_ENDPOINT"]? || config.endpoint)
      @model = ENV["GRAFITO_AI_MODEL"]? || config.default_model
      @timeout = Time::Span.new(seconds: 30)

      Log.info { "Initialized OpenAI-compatible provider: #{@provider_name}" }
      Log.info { "  Endpoint: #{@endpoint}" }
      Log.info { "  Model: #{@model}" }
    end

    def name : String
      "#{@provider_name} (#{@model})"
    end

    def self.available? : Bool
      !!(ENV["Z_AI_API_KEY"]? || ENV["OPENAI_API_KEY"]? ||
        ENV["GROQ_API_KEY"]? || ENV["TOGETHER_API_KEY"]? ||
        ENV["GRAFITO_AI_API_KEY"]? || ENV["GRAFITO_AI_ENDPOINT"]?)
    end

    def available? : Bool
      self.class.available?
    end

    def complete(request : Request) : Response
      Log.debug { "Sending completion request to #{@endpoint}" }
      Log.debug { "  Model: #{@model}" }
      Log.debug { "  Max tokens: #{request.max_tokens}" }

      start_time = Time.monotonic

      body = build_request_body(request)
      headers = build_headers

      client = HTTP::Client.new(@endpoint)
      client.read_timeout = @timeout
      client.connect_timeout = @timeout

      http_response = client.post(
        @endpoint.request_target,
        headers: headers,
        body: body
      )

      elapsed = Time.monotonic - start_time
      Log.debug { "API response received in #{elapsed.total_milliseconds.round(2)}ms" }
      Log.debug { "  Status: #{http_response.status_code}" }

      parse_response(http_response)
    rescue ex : IO::TimeoutError
      Log.error { "API request timed out after #{@timeout}" }
      raise Exception.new("AI request timed out. Please try again.")
    rescue ex : Exception
      Log.error(exception: ex) { "OpenAI-compatible API error: #{ex.message}" }
      raise ex
    end

    # Detect which provider to use based on available environment variables
    private def detect_provider : String
      # Check for explicit endpoint first (custom provider)
      if endpoint = ENV["GRAFITO_AI_ENDPOINT"]?
        if endpoint.includes?("localhost") || endpoint.includes?("127.0.0.1")
          return "ollama"
        end
      end

      # Check for provider-specific API keys in priority order
      return "z_ai" if ENV["Z_AI_API_KEY"]?
      return "openai" if ENV["OPENAI_API_KEY"]?
      return "groq" if ENV["GROQ_API_KEY"]?
      return "together" if ENV["TOGETHER_API_KEY"]?

      # Default to z_ai (backward compatible)
      "z_ai"
    end

    # Resolve the API key to use
    private def resolve_api_key(config : ProviderConfig) : String
      # Priority: Generic key > Provider-specific key > empty (for Ollama)
      ENV["GRAFITO_AI_API_KEY"]? ||
        config.env_key.try { |key| ENV[key]? } ||
        ""
    end

    # Build HTTP headers for the request
    private def build_headers : HTTP::Headers
      headers = HTTP::Headers{
        "Content-Type" => "application/json",
      }

      # Only add Authorization header if we have an API key
      unless @api_key.empty?
        headers["Authorization"] = "Bearer #{@api_key}"
      end

      headers
    end

    # Build the request body in OpenAI format
    private def build_request_body(request : Request) : String
      {
        model:       @model,
        max_tokens:  request.max_tokens,
        temperature: request.temperature,
        messages:    [
          {role: "system", content: request.system_prompt},
          {role: "user", content: request.user_prompt},
        ],
      }.to_json
    end

    # Parse the HTTP response into our Response type
    private def parse_response(http_response : HTTP::Client::Response) : Response
      body = http_response.body

      unless http_response.success?
        error_message = extract_error_message(body) || "HTTP #{http_response.status_code}"
        raise Exception.new("API error: #{error_message}")
      end

      json = JSON.parse(body)

      # Extract content from OpenAI format
      content = json.dig("choices", 0, "message", "content").as_s
      model = json["model"]?.try(&.as_s) || @model

      # Extract usage if available
      usage = if u = json["usage"]?
                Usage.new(
                  input_tokens: u["prompt_tokens"].as_i.to_i32,
                  output_tokens: u["completion_tokens"].as_i.to_i32
                )
              end

      Response.new(
        content: content,
        model: model,
        provider: @provider_name,
        usage: usage,
        raw: body
      )
    end

    # Try to extract a meaningful error message from the response
    private def extract_error_message(body : String) : String?
      json = JSON.parse(body)
      json.dig?("error", "message").try(&.as_s)
    rescue
      nil
    end
  end
end
