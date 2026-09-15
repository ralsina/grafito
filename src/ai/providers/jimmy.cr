# src/ai/providers/jimmy.cr
#
# ChatJimmy provider: talks directly to chatjimmy.ai's browser chat
# endpoint, which serves a free Llama 3.1 8B without requiring an API
# key. This is an in-process port of the translation layer from
# jimmy-proxy (https://github.com/Fadeleke57/jimmy-proxy), so grafito
# needs no external proxy process.
#
# Hidden behind a flag: the provider is never auto-detected and only
# runs when GRAFITO_AI_PROVIDER explicitly selects it.
#
# Configuration:
# - GRAFITO_AI_PROVIDER: must be "jimmy" or "chatjimmy" to enable
# - GRAFITO_AI_MODEL: model override (default: llama3.1-8B)
# - GRAFITO_AI_TIMEOUT_SEC: request timeout in seconds (default 120;
#   the free endpoint can be slow)
#
# Caveat: this is an unofficial use of a browser-facing endpoint. It
# can change or start rejecting requests at any time, which is why it
# stays disabled unless explicitly requested.

require "http/client"
require "json"
require "uri"
require "../provider"
require "../request"
require "../response"

module Grafito::AI::Providers
  # Provider for chatjimmy.ai's free (unofficial) chat endpoint.
  #
  # The upstream serves the fetch calls of a web chat page: there is no
  # authentication, requests must carry browser-like headers, the
  # system prompt travels inside `chatOptions` instead of a system
  # message, and the plain-text reply embeds token counters in a
  # `<|stats|>` block that has to be stripped before display.
  class Jimmy < Provider
    Log = ::Log.for(self)

    # Browser-facing chat endpoint (no auth, no API docs, no SLA).
    UPSTREAM = URI.parse("https://chatjimmy.ai/api/chat")

    DEFAULT_MODEL = "llama3.1-8B"

    # ChatJimmy returns empty responses when the system prompt exceeds
    # roughly 30K characters; stay below that with a safety margin.
    MAX_SYSTEM_PROMPT = 28000

    # Sampling setting the reference proxy was tuned with.
    TOP_K = 8

    # The upstream sits behind a CDN that frowns on non-browser clients.
    BROWSER_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"

    # The free endpoint currently serves a single model.
    KNOWN_MODELS = {
      "llama3.1-8B" => "Llama 3.1 8B",
    }

    # GRAFITO_AI_PROVIDER values that select this provider.
    SELECTOR_IDS = {"jimmy", "chatjimmy"}

    # Default request timeout; the free endpoint can be slow.
    DEFAULT_TIMEOUT_SEC = 120

    # Token counters arrive embedded in the reply inside
    # <|stats|>...<|/stats|>; capture them before stripping.
    STATS_REGEX = /<\|stats\|>(.*?)<\|\/stats\|>/m

    @model : String
    @timeout : Time::Span

    def initialize(model : String? = nil) : Nil
      @model = model || ENV["GRAFITO_AI_MODEL"]? || DEFAULT_MODEL
      @timeout = Time::Span.new(seconds: ENV["GRAFITO_AI_TIMEOUT_SEC"]?.try(&.to_i?) || DEFAULT_TIMEOUT_SEC)
      Log.info { "Initialized ChatJimmy provider (unofficial free endpoint)" }
      Log.info { "  Model: #{@model}" }
    end

    # True when `provider_id` names this provider.
    def self.selects?(provider_id : String) : Bool
      SELECTOR_IDS.includes?(provider_id)
    end

    # Hidden behind a flag: ChatJimmy is only available when
    # GRAFITO_AI_PROVIDER explicitly names it. It is never
    # auto-detected, because it is an unofficial free endpoint.
    def self.available? : Bool
      return false unless explicit = ENV["GRAFITO_AI_PROVIDER"]?
      selects?(explicit.downcase.strip)
    end

    def available? : Bool
      self.class.available?
    end

    def name : String
      "ChatJimmy (#{@model})"
    end

    def current_model : String
      @model
    end

    def models : Array(ModelInfo)
      KNOWN_MODELS.map do |model_id, model_name|
        ModelInfo.new(id: model_id, name: model_name, default: model_id == @model)
      end
    end

    def complete(request : Request) : Response
      Log.debug { "Sending completion request to #{UPSTREAM}" }
      Log.debug { "  Model: #{@model}" }

      start_time = Time.instant

      client = HTTP::Client.new(UPSTREAM)
      client.read_timeout = @timeout
      client.connect_timeout = @timeout

      http_response = client.post(
        UPSTREAM.request_target,
        headers: build_headers,
        body: build_request_body(request)
      )

      elapsed = Time.instant - start_time
      Log.debug { "ChatJimmy response received in #{elapsed.total_milliseconds.round(2)}ms" }
      Log.debug { "  Status: #{http_response.status_code}" }

      parse_response(http_response)
    rescue IO::TimeoutError
      Log.error { "ChatJimmy request timed out after #{@timeout}" }
      raise Exception.new("AI request timed out. Please try again.")
    rescue ex : Exception
      Log.error(exception: ex) { "ChatJimmy API error: #{ex.message}" }
      raise ex
    end

    # The upstream expects the headers a browser would send; there is
    # no API key to present.
    private def build_headers : HTTP::Headers
      HTTP::Headers{
        "Content-Type" => "application/json",
        "Accept"       => "*/*",
        "Origin"       => "https://chatjimmy.ai",
        "Referer"      => "https://chatjimmy.ai/",
        "User-Agent"   => BROWSER_USER_AGENT,
      }
    end

    # Translate a normalized request into ChatJimmy's format: the
    # system prompt moves into chatOptions, and the conversation is a
    # flat list of user/assistant messages.
    private def build_request_body(request : Request) : String
      messages = [{"role" => "user", "content" => request.user_prompt}]
      request.history.each do |message|
        messages << {"role" => message["role"], "content" => message["content"]}
      end

      {
        "messages":    messages,
        "chatOptions": {
          "selectedModel": @model,
          "systemPrompt":  truncated_system_prompt(request.system_prompt),
          "topK":          TOP_K,
        },
        "attachment": nil,
      }.to_json
    end

    private def truncated_system_prompt(prompt : String) : String
      return prompt if prompt.size <= MAX_SYSTEM_PROMPT

      Log.warn { "System prompt truncated from #{prompt.size} to #{MAX_SYSTEM_PROMPT} chars" }
      prompt[0, MAX_SYSTEM_PROMPT]
    end

    # ChatJimmy replies with plain text (not JSON). Token usage comes
    # embedded in a stats block that must never reach the UI.
    private def parse_response(http_response : HTTP::Client::Response) : Response
      raw_body = http_response.body

      unless http_response.success?
        raise Exception.new("API error: HTTP #{http_response.status_code}")
      end

      content = raw_body.gsub(STATS_REGEX, "").strip
      if content.empty?
        Log.warn { "ChatJimmy returned empty content" }
        raise Exception.new("API returned empty response")
      end

      Response.new(
        content: content,
        model: @model,
        provider: "ChatJimmy",
        usage: extract_usage(raw_body),
        raw: raw_body,
      )
    end

    private def extract_usage(raw_body : String) : Usage?
      stats_match = STATS_REGEX.match(raw_body)
      return unless stats_match

      stats = JSON.parse(stats_match[1])
      Usage.new(
        input_tokens: stats_int(stats["prefill_tokens"]?),
        output_tokens: stats_int(stats["decode_tokens"]?),
      )
    rescue JSON::ParseException
      Log.warn { "Could not parse ChatJimmy stats block" }
      nil
    end

    private def stats_int(value : JSON::Any?) : Int32
      value.try(&.as_i?.try(&.to_i32)) || 0
    end
  end
end
