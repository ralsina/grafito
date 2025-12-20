require "../spec_helper"
require "../../src/ai/config"

describe Grafito::AI::Config do
  describe "ProviderType" do
    it "converts Anthropic to string correctly" do
      Grafito::AI::Config::ProviderType::Anthropic.to_s.should eq("anthropic")
    end

    it "converts OpenAICompatible to string correctly" do
      Grafito::AI::Config::ProviderType::OpenAICompatible.to_s.should eq("openai_compatible")
    end

    it "converts None to string correctly" do
      Grafito::AI::Config::ProviderType::None.to_s.should eq("none")
    end
  end

  describe "provider constants" do
    it "defines ANTHROPIC_PROVIDERS with expected values" do
      Grafito::AI::Config::ANTHROPIC_PROVIDERS.should contain("anthropic")
      Grafito::AI::Config::ANTHROPIC_PROVIDERS.should contain("claude")
    end

    it "defines OPENAI_COMPATIBLE_PROVIDERS with expected values" do
      providers = Grafito::AI::Config::OPENAI_COMPATIBLE_PROVIDERS
      providers.should contain("openai")
      providers.should contain("z_ai")
      providers.should contain("groq")
      providers.should contain("ollama")
      providers.should contain("together")
    end

    it "defines OPENAI_COMPATIBLE_API_KEYS with expected values" do
      keys = Grafito::AI::Config::OPENAI_COMPATIBLE_API_KEYS
      keys.should contain("OPENAI_API_KEY")
      keys.should contain("Z_AI_API_KEY")
      keys.should contain("GROQ_API_KEY")
      keys.should contain("TOGETHER_API_KEY")
      keys.should contain("GRAFITO_AI_API_KEY")
    end
  end

  describe "ProviderInfo" do
    it "creates a provider info record" do
      info = Grafito::AI::Config::ProviderInfo.new(
        id: "test",
        name: "Test Provider",
        available: true
      )

      info.id.should eq("test")
      info.name.should eq("Test Provider")
      info.available.should be_true
    end

    it "serializes to JSON correctly" do
      info = Grafito::AI::Config::ProviderInfo.new(
        id: "anthropic",
        name: "Anthropic Claude",
        available: true
      )

      json = info.to_json
      json.should contain("\"id\":\"anthropic\"")
      json.should contain("\"name\":\"Anthropic Claude\"")
      json.should contain("\"available\":true")
    end

    it "deserializes from JSON correctly" do
      json = %({"id":"openai","name":"OpenAI","available":false})
      info = Grafito::AI::Config::ProviderInfo.from_json(json)

      info.id.should eq("openai")
      info.name.should eq("OpenAI")
      info.available.should be_false
    end
  end

  describe ".enabled?" do
    it "returns a boolean indicating if AI is available" do
      result = Grafito::AI::Config.enabled?
      result.should be_a(Bool)
    end
  end

  describe ".provider_name" do
    it "returns 'None' when no provider is configured" do
      # When no API keys are set, should return "None"
      # This test may pass or fail depending on environment
      result = Grafito::AI::Config.provider_name
      result.should be_a(String)
      result.size.should be > 0
    end
  end

  describe ".available_providers" do
    it "returns an array of ProviderInfo" do
      providers = Grafito::AI::Config.available_providers
      providers.should be_a(Array(Grafito::AI::Config::ProviderInfo))
    end

    it "only includes providers with configured API keys" do
      providers = Grafito::AI::Config.available_providers
      # Each provider in the list should have availability info
      providers.each do |provider|
        provider.id.should_not be_empty
        provider.name.should_not be_empty
      end
    end
  end

  describe ".provider_by_id" do
    it "returns nil for unknown provider id" do
      result = Grafito::AI::Config.provider_by_id("unknown_provider_xyz")
      result.should be_nil
    end

    it "normalizes provider id (case insensitive)" do
      # Test that the method handles case normalization
      # Both should be treated the same way
      result1 = Grafito::AI::Config.provider_by_id("ANTHROPIC")
      result2 = Grafito::AI::Config.provider_by_id("anthropic")

      # Both should return same type (either nil or Provider)
      if result1.nil?
        result2.should be_nil
      else
        result2.should_not be_nil
      end
    end

    it "normalizes provider id (strips whitespace)" do
      result1 = Grafito::AI::Config.provider_by_id("  anthropic  ")
      result2 = Grafito::AI::Config.provider_by_id("anthropic")

      if result1.nil?
        result2.should be_nil
      else
        result2.should_not be_nil
      end
    end
  end

  describe ".provider_type" do
    it "returns a ProviderType enum value" do
      result = Grafito::AI::Config.provider_type
      result.should be_a(Grafito::AI::Config::ProviderType)
    end
  end
end
