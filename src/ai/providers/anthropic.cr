# src/ai/providers/anthropic.cr
#
# Anthropic/Claude provider using the jgaskins/anthropic shard.
#
# Configuration:
# - ANTHROPIC_API_KEY: Required API key
# - GRAFITO_AI_MODEL: Optional model override (default: claude-sonnet-4-5-20250929)

require "anthropic"
require "../provider"
require "../request"
require "../response"

module Grafito::AI::Providers
  # Anthropic/Claude provider using the jgaskins/anthropic shard.
  #
  # The shard handles:
  # - API authentication
  # - Request formatting
  # - Response parsing
  class Anthropic < Provider
    Log = ::Log.for(self)

    # Default model if not overridden
    DEFAULT_MODEL = "claude-sonnet-4-5-20250929"

    # Known Claude models (Anthropic has no public models API)
    # Ordered by capability/recency
    KNOWN_MODELS = {
      "claude-sonnet-4-5-20250929" => "Claude Sonnet 4.5",
      "claude-opus-4-20250514"     => "Claude Opus 4",
      "claude-sonnet-4-20250514"   => "Claude Sonnet 4",
      "claude-3-5-sonnet-20241022" => "Claude 3.5 Sonnet",
      "claude-3-5-haiku-20241022"  => "Claude 3.5 Haiku",
      "claude-3-opus-20240229"     => "Claude 3 Opus",
      "claude-3-haiku-20240307"    => "Claude 3 Haiku",
    }

    # Anthropic client from jgaskins/anthropic shard
    @client : ::Anthropic::Client

    # Model to use for completions
    @model : String

    def initialize(model : String? = nil) : Nil
      @client = ::Anthropic::Client.new
      @model = model || ENV["GRAFITO_AI_MODEL"]? || DEFAULT_MODEL
      Log.info { "Initialized Anthropic provider with model: #{@model}" }
    end

    def name : String
      "Anthropic Claude (#{@model})"
    end

    def self.available? : Bool
      !!ENV["ANTHROPIC_API_KEY"]?
    end

    def available? : Bool
      self.class.available?
    end

    # Returns known Claude models (Anthropic has no public models API)
    def models : Array(ModelInfo)
      KNOWN_MODELS.map do |id, name|
        ModelInfo.new(id: id, name: name, default: id == @model)
      end
    end

    def current_model : String
      @model
    end

    def complete(request : Request) : Response
      Log.debug { "Sending completion request to Anthropic API" }
      Log.debug { "  Model: #{@model}" }
      Log.debug { "  Max tokens: #{request.max_tokens}" }
      Log.debug { "  Temperature: #{request.temperature}" }

      start_time = Time.monotonic

      # Use the jgaskins/anthropic shard's Messages API
      anthropic_response = @client.messages.create(
        model: @model,
        system: request.system_prompt,
        messages: [
          ::Anthropic::Message.new(request.user_prompt),
        ],
        max_tokens: request.max_tokens,
        temperature: request.temperature
      )

      elapsed = Time.monotonic - start_time
      Log.debug { "Anthropic API response received in #{elapsed.total_milliseconds.round(2)}ms" }

      # Extract content from response
      content = extract_content(anthropic_response)
      usage = extract_usage(anthropic_response)

      Response.new(
        content: content,
        model: @model,
        provider: "Anthropic",
        usage: usage
      )
    rescue ex : Exception
      Log.error(exception: ex) { "Anthropic API error: #{ex.message}" }
      raise ex
    end

    # Extract text content from Anthropic response
    private def extract_content(response) : String
      # The response contains an array of content blocks
      # We join all text blocks together
      content_parts = Array(String).new

      response.content.each do |block|
        case block
        when ::Anthropic::Text
          content_parts << block.text unless block.text.empty?
        end
      end

      content = content_parts.join("\n")

      if content.empty?
        Log.warn { "Anthropic API returned empty content" }
        raise Exception.new("API returned empty response")
      end

      content
    end

    # Extract usage statistics from Anthropic response
    private def extract_usage(response) : Usage?
      usage = response.usage
      Usage.new(
        input_tokens: usage.input_tokens.to_i32,
        output_tokens: usage.output_tokens.to_i32
      )
    rescue
      nil
    end
  end
end
