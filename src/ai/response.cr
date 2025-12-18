# src/ai/response.cr
#
# Normalized AI response type returned by all providers.
# Contains the generated content plus metadata.

require "json"

module Grafito::AI
  # Token usage statistics
  struct Usage
    include JSON::Serializable

    getter input_tokens : Int32
    getter output_tokens : Int32

    def initialize(@input_tokens : Int32, @output_tokens : Int32)
    end

    def total_tokens : Int32
      input_tokens + output_tokens
    end
  end

  # Normalized AI response from any provider.
  # Contains the generated content plus metadata.
  struct Response
    include JSON::Serializable

    # The generated text content
    getter content : String

    # Model that generated this response
    getter model : String

    # Provider identifier (e.g., "anthropic", "openai_compatible")
    getter provider : String

    # Optional token usage statistics
    getter usage : Usage?

    # Optional raw response for debugging (not serialized by default)
    @[JSON::Field(ignore: true)]
    getter raw : String?

    def initialize(
      @content : String,
      @model : String,
      @provider : String,
      @usage : Usage? = nil,
      @raw : String? = nil,
    )
    end

    # Check if this response contains meaningful content
    def empty? : Bool
      content.blank?
    end
  end
end
