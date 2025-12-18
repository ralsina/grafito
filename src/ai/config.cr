# src/ai/config.cr
#
# Configuration management for AI providers.
# Supports both explicit provider selection and auto-detection.

require "./provider"
require "./providers/anthropic"
require "./providers/openai_compatible"

module Grafito::AI
  # Configuration management for AI providers.
  #
  # Supports both explicit provider selection via GRAFITO_AI_PROVIDER
  # and auto-detection based on available API keys.
  #
  # Environment Variables:
  # - GRAFITO_AI_PROVIDER: Force specific provider (anthropic, openai, z_ai, groq, ollama)
  # - ANTHROPIC_API_KEY: Anthropic/Claude API key
  # - Z_AI_API_KEY: Z.AI API key (backward compatible)
  # - OPENAI_API_KEY: OpenAI API key
  # - GROQ_API_KEY: Groq API key
  # - TOGETHER_API_KEY: Together.ai API key
  # - GRAFITO_AI_API_KEY: Generic API key (fallback)
  # - GRAFITO_AI_MODEL: Override default model
  # - GRAFITO_AI_ENDPOINT: Custom endpoint URL (for Ollama, etc.)
  module Config
    extend self

    Log = ::Log.for(self)

    # Supported provider types
    enum ProviderType
      Anthropic
      OpenAICompatible
      None

      def to_s : String
        case self
        when .anthropic?          then "anthropic"
        when .open_ai_compatible? then "openai_compatible"
        else                           "none"
        end
      end
    end

    # Get an instance of the configured provider, or nil if none available
    def provider : Provider?
      case provider_type
      when .anthropic?
        Providers::Anthropic.new if Providers::Anthropic.available?
      when .open_ai_compatible?
        Providers::OpenAICompatible.new if Providers::OpenAICompatible.available?
      else
        nil
      end
    end

    # Determine which provider type to use
    def provider_type : ProviderType
      # Check for explicit provider selection
      if explicit = ENV["GRAFITO_AI_PROVIDER"]?
        case explicit.downcase.strip
        when "anthropic", "claude"
          Log.debug { "Explicit provider selection: Anthropic" }
          return ProviderType::Anthropic
        when "openai", "z_ai", "zai", "groq", "ollama", "together", "openai_compatible"
          Log.debug { "Explicit provider selection: OpenAI-Compatible" }
          return ProviderType::OpenAICompatible
        else
          Log.warn { "Unknown provider '#{explicit}', falling back to auto-detection" }
        end
      end

      # Auto-detect based on available API keys (priority order)
      if ENV["ANTHROPIC_API_KEY"]?
        Log.debug { "Auto-detected provider: Anthropic (ANTHROPIC_API_KEY present)" }
        ProviderType::Anthropic
      elsif ENV["Z_AI_API_KEY"]? || ENV["OPENAI_API_KEY"]? || ENV["GROQ_API_KEY"]? ||
            ENV["TOGETHER_API_KEY"]? || ENV["GRAFITO_AI_API_KEY"]?
        Log.debug { "Auto-detected provider: OpenAI-Compatible" }
        ProviderType::OpenAICompatible
      elsif ENV["GRAFITO_AI_ENDPOINT"]?
        # Custom endpoint (like Ollama) without API key
        Log.debug { "Auto-detected provider: OpenAI-Compatible (custom endpoint)" }
        ProviderType::OpenAICompatible
      else
        Log.debug { "No AI provider detected" }
        ProviderType::None
      end
    end

    # Check if any AI provider is available
    def enabled? : Bool
      !provider.nil?
    end

    # Get human-readable name of the active provider
    def provider_name : String
      provider.try(&.name) || "None"
    end

    # Available provider info for frontend
    record ProviderInfo, id : String, name : String, available : Bool do
      include JSON::Serializable
    end

    # List all available providers with their status
    def available_providers : Array(ProviderInfo)
      providers = [] of ProviderInfo

      # Check Anthropic
      if ENV["ANTHROPIC_API_KEY"]?
        providers << ProviderInfo.new(
          id: "anthropic",
          name: "Anthropic Claude",
          available: Providers::Anthropic.available?
        )
      end

      # Check OpenAI-compatible providers
      if ENV["Z_AI_API_KEY"]?
        providers << ProviderInfo.new(id: "z_ai", name: "Z.AI", available: true)
      end

      if ENV["OPENAI_API_KEY"]?
        providers << ProviderInfo.new(id: "openai", name: "OpenAI", available: true)
      end

      if ENV["GROQ_API_KEY"]?
        providers << ProviderInfo.new(id: "groq", name: "Groq", available: true)
      end

      if ENV["TOGETHER_API_KEY"]?
        providers << ProviderInfo.new(id: "together", name: "Together.ai", available: true)
      end

      if ENV["OLLAMA_HOST"]? || ENV["GRAFITO_AI_ENDPOINT"]?.try(&.includes?("localhost"))
        providers << ProviderInfo.new(id: "ollama", name: "Ollama (local)", available: true)
      end

      providers
    end

    # Get a specific provider by ID
    def provider_by_id(id : String) : Provider?
      case id.downcase.strip
      when "anthropic", "claude"
        Providers::Anthropic.new if Providers::Anthropic.available?
      when "z_ai", "zai", "openai", "groq", "together", "ollama", "openai_compatible"
        # For OpenAI-compatible, we need to temporarily set the detection
        Providers::OpenAICompatible.new(id) if Providers::OpenAICompatible.available?
      else
        nil
      end
    end

    # Log current configuration (for debugging)
    def log_config
      Log.info { "AI Provider Configuration:" }
      Log.info { "  Provider Type: #{provider_type}" }
      Log.info { "  Provider Name: #{provider_name}" }
      Log.info { "  Enabled: #{enabled?}" }
      Log.info { "  Model Override: #{ENV["GRAFITO_AI_MODEL"]? || "(default)"}" }
      Log.info { "  Endpoint Override: #{ENV["GRAFITO_AI_ENDPOINT"]? || "(default)"}" }
    end
  end
end
