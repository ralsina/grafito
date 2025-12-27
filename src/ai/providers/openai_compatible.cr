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
      models_endpoint : String?,
      default_model : String,
      env_key : String?,
      name : String

    PROVIDERS = {
      "z_ai" => ProviderConfig.new(
        endpoint: "https://api.z.ai/api/paas/v4/chat/completions",
        models_endpoint: nil, # Z.AI doesn't expose models list
        default_model: "glm-4.5-flash",
        env_key: "Z_AI_API_KEY",
        name: "Z.AI"
      ),
      "openai" => ProviderConfig.new(
        endpoint: "https://api.openai.com/v1/chat/completions",
        models_endpoint: "https://api.openai.com/v1/models",
        default_model: "gpt-4o-mini",
        env_key: "OPENAI_API_KEY",
        name: "OpenAI"
      ),
      "groq" => ProviderConfig.new(
        endpoint: "https://api.groq.com/openai/v1/chat/completions",
        models_endpoint: "https://api.groq.com/openai/v1/models",
        default_model: "llama-3.1-70b-versatile",
        env_key: "GROQ_API_KEY",
        name: "Groq"
      ),
      "together" => ProviderConfig.new(
        endpoint: "https://api.together.xyz/v1/chat/completions",
        models_endpoint: "https://api.together.xyz/v1/models",
        default_model: "meta-llama/Llama-3-70b-chat-hf",
        env_key: "TOGETHER_API_KEY",
        name: "Together.ai"
      ),
      "ollama" => ProviderConfig.new(
        endpoint: "http://localhost:11434/v1/chat/completions",
        models_endpoint: "http://localhost:11434/api/tags",
        default_model: "llama3",
        env_key: nil,
        name: "Ollama"
      ),
    }

    # Curated list of popular, known-working chat models per provider
    KNOWN_MODELS = {
      "z_ai" => {
        "glm-4.5-flash" => "GLM 4.5 Flash",
        "glm-4-plus"    => "GLM 4 Plus",
      },
      "openai" => {
        # GPT-5 series (chat-compatible)
        "gpt-5.2"    => "GPT-5.2",
        "gpt-5.1"    => "GPT-5.1",
        "gpt-5"      => "GPT-5",
        "gpt-5-mini" => "GPT-5 Mini",
        "gpt-5-nano" => "GPT-5 Nano",
        # O1 reasoning models
        "o1" => "O1",
        # GPT-4.1 series
        "gpt-4.1"      => "GPT-4.1",
        "gpt-4.1-mini" => "GPT-4.1 Mini",
        "gpt-4.1-nano" => "GPT-4.1 Nano",
        # GPT-4o series
        "gpt-4o"            => "GPT-4o",
        "gpt-4o-mini"       => "GPT-4o Mini",
        "chatgpt-4o-latest" => "ChatGPT-4o Latest",
        # GPT-4 series
        "gpt-4-turbo" => "GPT-4 Turbo",
        "gpt-4"       => "GPT-4",
        # GPT-3.5 series
        "gpt-3.5-turbo"     => "GPT-3.5 Turbo",
        "gpt-3.5-turbo-16k" => "GPT-3.5 Turbo 16K",
      },
      "groq" => {
        "llama-3.3-70b-versatile" => "Llama 3.3 70B",
        "llama-3.1-8b-instant"    => "Llama 3.1 8B",
        "mixtral-8x7b-32768"      => "Mixtral 8x7B",
        "gemma2-9b-it"            => "Gemma 2 9B",
      },
      "together" => {
        "meta-llama/Llama-3.3-70B-Instruct-Turbo"        => "Llama 3.3 70B",
        "meta-llama/Llama-3.2-11B-Vision-Instruct-Turbo" => "Llama 3.2 11B Vision",
        "mistralai/Mixtral-8x7B-Instruct-v0.1"           => "Mixtral 8x7B",
      },
      "ollama" => {
        "llama3.2"  => "Llama 3.2",
        "llama3.1"  => "Llama 3.1",
        "mistral"   => "Mistral",
        "codellama" => "Code Llama",
        "qwen2.5"   => "Qwen 2.5",
      },
    }

    @api_key : String
    @endpoint : URI
    @model : String
    @provider_name : String
    @provider_id : String
    @models_endpoint : String?
    @timeout : Time::Span
    @cached_models : Array(ModelInfo)?

    def initialize(force_provider : String? = nil, model : String? = nil) : Nil
      @provider_id = force_provider || detect_provider
      config = PROVIDERS[@provider_id]? || PROVIDERS["z_ai"]

      @provider_name = config.name
      @api_key = resolve_api_key(config)
      @endpoint = URI.parse(ENV["GRAFITO_AI_ENDPOINT"]? || config.endpoint)
      @models_endpoint = config.models_endpoint
      @model = model || ENV["GRAFITO_AI_MODEL"]? || config.default_model
      @timeout = Time::Span.new(seconds: 30)
      @cached_models = nil

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

    def current_model : String
      @model
    end

    # Fetch available models from API or return fallback list
    def models : Array(ModelInfo)
      @cached_models ||= fetch_models
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
      # Newer models (gpt-5, o1) use max_completion_tokens instead of max_tokens
      if uses_completion_tokens?
        {
          model:                 @model,
          max_completion_tokens: request.max_tokens,
          messages:              [
            {role: "system", content: request.system_prompt},
            {role: "user", content: request.user_prompt},
          ],
        }.to_json
      else
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
    end

    # Check if model uses max_completion_tokens instead of max_tokens
    private def uses_completion_tokens? : Bool
      @model.starts_with?("gpt-5") || @model.starts_with?("o1")
    end

    # Parse the HTTP response into our Response type
    private def parse_response(http_response : HTTP::Client::Response) : Response
      body = http_response.body

      unless http_response.success?
        error_message = extract_error_message(body) || "HTTP #{http_response.status_code}"
        raise Exception.new("API error: #{error_message}")
      end

      json = begin
        JSON.parse(body)
      rescue ex : JSON::ParseException
        Log.error { "Failed to parse API response as JSON: #{ex.message}" }
        raise Exception.new("Invalid response from API: malformed JSON")
      end

      # Extract content from OpenAI format with validation
      content = json.dig?("choices", 0, "message", "content").try(&.as_s?)
      unless content
        Log.error { "Malformed API response: missing choices[0].message.content" }
        Log.debug { "Response body: #{body}" }
        raise Exception.new("Invalid response from API: missing content field")
      end

      if content.empty?
        Log.warn { "API returned empty content" }
        raise Exception.new("API returned empty response")
      end

      model = json["model"]?.try(&.as_s) || @model

      # Extract usage if available (non-critical, don't fail on missing)
      usage = extract_usage(json)

      Response.new(
        content: content,
        model: model,
        provider: @provider_name,
        usage: usage,
        raw: body
      )
    end

    # Extract integer from JSON::Any safely
    private def json_int(value : JSON::Any?) : Int32
      value.try(&.as_i?.try(&.to_i32)) || 0
    end

    # Extract usage statistics from response (returns nil if unavailable)
    private def extract_usage(json : JSON::Any) : Usage?
      return unless u = json["usage"]?

      Usage.new(
        input_tokens: json_int(u["prompt_tokens"]?),
        output_tokens: json_int(u["completion_tokens"]?)
      )
    end

    # Try to extract a meaningful error message from the response
    private def extract_error_message(body : String) : String?
      json = JSON.parse(body)
      json.dig?("error", "message").try(&.as_s)
    rescue
      nil
    end

    # Get models list - use curated list for cloud providers, dynamic for Ollama
    private def fetch_models : Array(ModelInfo)
      # For Ollama, try to fetch installed models dynamically
      if @provider_id == "ollama" && (models_url = @models_endpoint)
        models = fetch_ollama_models(URI.parse(models_url))
        return models unless models.empty?
      end

      # Use curated list for all other providers (or Ollama fallback)
      known_models
    rescue ex
      Log.warn { "Failed to fetch models: #{ex.message}, using curated list" }
      known_models
    end

    # Fetch locally installed models from Ollama's /api/tags endpoint
    private def fetch_ollama_models(endpoint : URI) : Array(ModelInfo)
      client = HTTP::Client.new(endpoint)
      client.read_timeout = Time::Span.new(seconds: 5)

      response = client.get(endpoint.request_target)
      return [] of ModelInfo unless response.success?

      json = JSON.parse(response.body)
      models = json["models"]?.try(&.as_a) || return [] of ModelInfo

      models.compact_map do |item|
        name = item["name"]?.try(&.as_s) || next
        # Strip :latest tag for cleaner display
        id = name.sub(/:latest$/, "")
        ModelInfo.new(id: id, name: format_model_name(id), default: id == @model)
      end.sort_by!(&.name)
    end

    # Format model ID into human-readable name
    private def format_model_name(id : String) : String
      id.gsub("-", " ").gsub("_", " ").split.map(&.capitalize).join(" ")
    end

    # Return curated models for this provider
    private def known_models : Array(ModelInfo)
      models = KNOWN_MODELS[@provider_id]? || {} of String => String
      models.map { |id, name| ModelInfo.new(id: id, name: name, default: id == @model) }
    end
  end
end
