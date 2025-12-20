# src/ai/provider.cr
#
# Abstract base class for AI providers.
# Each provider must implement the core interface for completion requests.

require "json"
require "./request"
require "./response"

module Grafito::AI
  # Model information for frontend display
  record ModelInfo, id : String, name : String, default : Bool = false do
    include JSON::Serializable
  end

  # Abstract base class for AI providers.
  #
  # Each provider must implement:
  # - `name` - Human-readable provider name
  # - `complete` - Execute a completion request
  # - `available?` - Check if provider can be used
  # - `models` - List available models
  # - `current_model` - Get currently selected model
  abstract class Provider
    Log = ::Log.for(self)

    # Human-readable name for this provider instance
    abstract def name : String

    # Execute a completion request and return normalized response
    abstract def complete(request : Request) : Response

    # Check if this provider can be used (has required config)
    abstract def available? : Bool

    # List available models for this provider
    abstract def models : Array(ModelInfo)

    # Get the currently selected model ID
    abstract def current_model : String

    # Class method version of available? for factory use
    def self.available? : Bool
      false # Override in subclasses
    end
  end
end
