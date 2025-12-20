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
      end
    end

    # Provider IDs that map to Anthropic
    ANTHROPIC_PROVIDERS = {"anthropic", "claude"}

    # Provider IDs that map to OpenAI-compatible
    OPENAI_COMPATIBLE_PROVIDERS = {"openai", "z_ai", "zai", "groq", "ollama", "together", "openai_compatible"}

    # API key environment variables for OpenAI-compatible providers
    OPENAI_COMPATIBLE_API_KEYS = {"Z_AI_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY", "TOGETHER_API_KEY", "GRAFITO_AI_API_KEY"}

    # Determine which provider type to use
    def provider_type : ProviderType
      # Check for explicit provider selection first
      if result = parse_explicit_provider
        return result
      end

      # Fall back to auto-detection
      auto_detect_provider
    end

    # Parse explicit provider from GRAFITO_AI_PROVIDER env var
    private def parse_explicit_provider : ProviderType?
      return unless explicit = ENV["GRAFITO_AI_PROVIDER"]?

      normalized = explicit.downcase.strip
      if ANTHROPIC_PROVIDERS.includes?(normalized)
        Log.debug { "Explicit provider selection: Anthropic" }
        ProviderType::Anthropic
      elsif OPENAI_COMPATIBLE_PROVIDERS.includes?(normalized)
        Log.debug { "Explicit provider selection: OpenAI-Compatible" }
        ProviderType::OpenAICompatible
      else
        Log.warn { "Unknown provider '#{explicit}', falling back to auto-detection" }
        nil
      end
    end

    # Auto-detect provider based on available API keys
    private def auto_detect_provider : ProviderType
      if ENV["ANTHROPIC_API_KEY"]?
        Log.debug { "Auto-detected provider: Anthropic (ANTHROPIC_API_KEY present)" }
        return ProviderType::Anthropic
      end

      if OPENAI_COMPATIBLE_API_KEYS.any? { |key| ENV[key]? }
        Log.debug { "Auto-detected provider: OpenAI-Compatible" }
        return ProviderType::OpenAICompatible
      end

      if ENV["GRAFITO_AI_ENDPOINT"]?
        Log.debug { "Auto-detected provider: OpenAI-Compatible (custom endpoint)" }
        return ProviderType::OpenAICompatible
      end

      Log.debug { "No AI provider detected" }
      ProviderType::None
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
      providers = Array(ProviderInfo).new

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

    # Get a specific provider by ID, optionally with a specific model
    def provider_by_id(id : String, model : String? = nil) : Provider?
      normalized_id = id.downcase.strip

      if ANTHROPIC_PROVIDERS.includes?(normalized_id)
        Providers::Anthropic.new(model) if Providers::Anthropic.available?
      elsif OPENAI_COMPATIBLE_PROVIDERS.includes?(normalized_id)
        Providers::OpenAICompatible.new(normalized_id, model) if Providers::OpenAICompatible.available?
      end
    end

    # Get available models for a specific provider
    def models_for_provider(id : String) : Array(ModelInfo)
      provider = provider_by_id(id)
      provider.try(&.models) || [] of ModelInfo
    end

    # Log current configuration (for debugging)
    def log_config : Nil
      Log.info { "AI Provider Configuration:" }
      Log.info { "  Provider Type: #{provider_type}" }
      Log.info { "  Provider Name: #{provider_name}" }
      Log.info { "  Enabled: #{enabled?}" }
      Log.info { "  Model Override: #{ENV["GRAFITO_AI_MODEL"]? || "(default)"}" }
      Log.info { "  Endpoint Override: #{ENV["GRAFITO_AI_ENDPOINT"]? || "(default)"}" }
    end
  end
end
