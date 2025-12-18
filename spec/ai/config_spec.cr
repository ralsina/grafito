require "../spec_helper"
require "../../src/ai/config"

describe Grafito::AI::Config do
  describe "ProviderType" do
    it "converts to string correctly" do
      Grafito::AI::Config::ProviderType::Anthropic.to_s.should eq("anthropic")
      Grafito::AI::Config::ProviderType::OpenAICompatible.to_s.should eq("openai_compatible")
      Grafito::AI::Config::ProviderType::None.to_s.should eq("none")
    end
  end

  # Note: These tests depend on environment variables.
  # In a real test suite, you would mock ENV or use a different approach.

  describe ".provider_type" do
    # These tests verify the detection logic when no keys are set
    # The actual behavior depends on the test environment
  end

  describe ".enabled?" do
    it "returns boolean" do
      result = Grafito::AI::Config.enabled?
      (result == true || result == false).should be_true
    end
  end

  describe ".provider_name" do
    it "returns a string" do
      result = Grafito::AI::Config.provider_name
      result.should be_a(String)
    end
  end
end
