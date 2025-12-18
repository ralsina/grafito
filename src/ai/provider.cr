# src/ai/provider.cr
#
# Abstract base class for AI providers.
# Each provider must implement the core interface for completion requests.

require "./request"
require "./response"

module Grafito::AI
  # Abstract base class for AI providers.
  #
  # Each provider must implement:
  # - `name` - Human-readable provider name
  # - `complete` - Execute a completion request
  # - `available?` - Check if provider can be used
  #
  # Example implementation:
  # ```
  # class MyProvider < Provider
  #   def name : String
  #     "MyProvider (#{@model})"
  #   end
  #
  #   def complete(request : Request) : Response
  #     # Transform request, call API, return Response
  #   end
  #
  #   def available? : Bool
  #     !ENV["MY_API_KEY"]?.nil?
  #   end
  # end
  # ```
  abstract class Provider
    Log = ::Log.for(self)

    # Human-readable name for this provider instance
    # Should include model name if relevant
    abstract def name : String

    # Execute a completion request and return normalized response
    # Raises on API errors
    abstract def complete(request : Request) : Response

    # Check if this provider can be used (has required config)
    abstract def available? : Bool

    # Class method version of available? for factory use
    def self.available? : Bool
      false # Override in subclasses
    end
  end
end
