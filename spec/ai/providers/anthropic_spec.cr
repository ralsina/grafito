require "../../spec_helper"
require "../../../src/ai/providers/anthropic"

describe Grafito::AI::Providers::Anthropic do
  describe "DEFAULT_MODEL" do
    it "is the expected Claude model" do
      Grafito::AI::Providers::Anthropic::DEFAULT_MODEL.should eq("claude-sonnet-4-5-20250929")
    end
  end

  describe ".available?" do
    it "returns true when ANTHROPIC_API_KEY is set" do
      ENV["ANTHROPIC_API_KEY"] = "test-key"
      Grafito::AI::Providers::Anthropic.available?.should be_true
    end
  end

  describe "#name" do
    it "returns provider name with default model" do
      ENV["ANTHROPIC_API_KEY"] = "test-key-for-spec"
      ENV["GRAFITO_AI_MODEL"] = nil

      provider = Grafito::AI::Providers::Anthropic.new
      provider.name.should eq("Anthropic Claude (#{Grafito::AI::Providers::Anthropic::DEFAULT_MODEL})")
    end

    it "uses custom model when GRAFITO_AI_MODEL is set" do
      ENV["ANTHROPIC_API_KEY"] = "test-key-for-spec"
      ENV["GRAFITO_AI_MODEL"] = "claude-3-haiku-20240307"

      provider = Grafito::AI::Providers::Anthropic.new
      provider.name.should eq("Anthropic Claude (claude-3-haiku-20240307)")
    end
  end

  describe "#available?" do
    it "delegates to class method" do
      ENV["ANTHROPIC_API_KEY"] = "test-key"
      provider = Grafito::AI::Providers::Anthropic.new
      provider.available?.should be_true
    end
  end

  describe "#complete" do
    before_each do
      WebMock.reset
      ENV["ANTHROPIC_API_KEY"] = "test-key"
      ENV["GRAFITO_AI_MODEL"] = nil
    end

    it "returns a response with content from the API" do
      WebMock.stub(:post, "https://api.anthropic.com/v1/messages?beta=tools")
        .to_return(status: 200, body: {
          id:          "msg_123",
          type:        "message",
          role:        "assistant",
          content:     [{type: "text", text: "This is a test response from Claude"}],
          model:       "claude-sonnet-4-5-20250929",
          stop_reason: "end_turn",
          usage:       {input_tokens: 15, output_tokens: 25},
        }.to_json)

      provider = Grafito::AI::Providers::Anthropic.new
      request = Grafito::AI::Request.new(
        system_prompt: "You are helpful",
        user_prompt: "Hello"
      )

      response = provider.complete(request)
      response.content.should eq("This is a test response from Claude")
      response.model.should eq("claude-sonnet-4-5-20250929")
      response.provider.should eq("Anthropic")
    end

    it "parses usage statistics from the response" do
      WebMock.stub(:post, "https://api.anthropic.com/v1/messages?beta=tools")
        .to_return(status: 200, body: {
          id:          "msg_456",
          type:        "message",
          role:        "assistant",
          content:     [{type: "text", text: "Response"}],
          model:       "claude-sonnet-4-5-20250929",
          stop_reason: "end_turn",
          usage:       {input_tokens: 100, output_tokens: 200},
        }.to_json)

      provider = Grafito::AI::Providers::Anthropic.new
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      response = provider.complete(request)
      response.usage.should_not be_nil
      response.usage.try(&.input_tokens).should eq(100)
      response.usage.try(&.output_tokens).should eq(200)
    end

    it "raises an error on API failure" do
      WebMock.stub(:post, "https://api.anthropic.com/v1/messages?beta=tools")
        .to_return(status: 401, body: {
          type:  "error",
          error: {type: "authentication_error", message: "Invalid API key"},
        }.to_json)

      provider = Grafito::AI::Providers::Anthropic.new
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      expect_raises(Exception) do
        provider.complete(request)
      end
    end
  end
end
