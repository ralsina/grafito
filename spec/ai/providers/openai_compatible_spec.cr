require "../../spec_helper"
require "../../../src/ai/providers/openai_compatible"

describe Grafito::AI::Providers::OpenAICompatible do
  describe "PROVIDERS" do
    it "contains z_ai as the default backward-compatible provider" do
      config = Grafito::AI::Providers::OpenAICompatible::PROVIDERS["z_ai"]
      config.name.should eq("Z.AI")
      config.env_key.should eq("Z_AI_API_KEY")
      config.default_model.should eq("glm-4.5-flash")
    end

    it "contains openai configuration" do
      config = Grafito::AI::Providers::OpenAICompatible::PROVIDERS["openai"]
      config.name.should eq("OpenAI")
      config.env_key.should eq("OPENAI_API_KEY")
      config.endpoint.should contain("api.openai.com")
    end

    it "contains groq configuration" do
      config = Grafito::AI::Providers::OpenAICompatible::PROVIDERS["groq"]
      config.name.should eq("Groq")
      config.env_key.should eq("GROQ_API_KEY")
      config.endpoint.should contain("api.groq.com")
    end

    it "contains together configuration" do
      config = Grafito::AI::Providers::OpenAICompatible::PROVIDERS["together"]
      config.name.should eq("Together.ai")
      config.env_key.should eq("TOGETHER_API_KEY")
    end

    it "contains ollama configuration without API key requirement" do
      config = Grafito::AI::Providers::OpenAICompatible::PROVIDERS["ollama"]
      config.name.should eq("Ollama")
      config.env_key.should be_nil
      config.endpoint.should contain("localhost")
    end

    it "has 5 known providers" do
      Grafito::AI::Providers::OpenAICompatible::PROVIDERS.size.should eq(5)
    end
  end

  describe ".available?" do
    it "returns true when Z_AI_API_KEY is set" do
      ENV["Z_AI_API_KEY"] = "test"
      Grafito::AI::Providers::OpenAICompatible.available?.should be_true
    end

    it "returns true when OPENAI_API_KEY is set" do
      ENV["OPENAI_API_KEY"] = "test"
      Grafito::AI::Providers::OpenAICompatible.available?.should be_true
    end

    it "returns true when GROQ_API_KEY is set" do
      ENV["GROQ_API_KEY"] = "test"
      Grafito::AI::Providers::OpenAICompatible.available?.should be_true
    end

    it "returns true when TOGETHER_API_KEY is set" do
      ENV["TOGETHER_API_KEY"] = "test"
      Grafito::AI::Providers::OpenAICompatible.available?.should be_true
    end

    it "returns true when GRAFITO_AI_API_KEY is set" do
      ENV["GRAFITO_AI_API_KEY"] = "test"
      Grafito::AI::Providers::OpenAICompatible.available?.should be_true
    end

    it "returns true when GRAFITO_AI_ENDPOINT is set" do
      ENV["GRAFITO_AI_ENDPOINT"] = "http://localhost:11434"
      Grafito::AI::Providers::OpenAICompatible.available?.should be_true
    end
  end

  describe "#name" do
    before_each do
      ENV["Z_AI_API_KEY"] = nil
      ENV["OPENAI_API_KEY"] = nil
      ENV["GROQ_API_KEY"] = nil
      ENV["TOGETHER_API_KEY"] = nil
      ENV["GRAFITO_AI_API_KEY"] = nil
      ENV["GRAFITO_AI_ENDPOINT"] = nil
      ENV["GRAFITO_AI_MODEL"] = nil
    end

    it "returns provider name with model for Z.AI" do
      ENV["Z_AI_API_KEY"] = "test-key"
      provider = Grafito::AI::Providers::OpenAICompatible.new
      provider.name.should eq("Z.AI (glm-4.5-flash)")
    end

    it "returns provider name with model for OpenAI" do
      ENV["OPENAI_API_KEY"] = "test-key"
      provider = Grafito::AI::Providers::OpenAICompatible.new
      provider.name.should eq("OpenAI (gpt-4o-mini)")
    end

    it "returns provider name with model for Groq" do
      ENV["GROQ_API_KEY"] = "test-key"
      provider = Grafito::AI::Providers::OpenAICompatible.new
      provider.name.should eq("Groq (llama-3.1-70b-versatile)")
    end

    it "uses custom model when GRAFITO_AI_MODEL is set" do
      ENV["Z_AI_API_KEY"] = "test-key"
      ENV["GRAFITO_AI_MODEL"] = "custom-model"
      provider = Grafito::AI::Providers::OpenAICompatible.new
      provider.name.should eq("Z.AI (custom-model)")
    end
  end

  describe "#available?" do
    it "returns true when Z_AI_API_KEY is set" do
      ENV["Z_AI_API_KEY"] = "test-key"
      provider = Grafito::AI::Providers::OpenAICompatible.new
      provider.available?.should be_true
    end

    it "returns true when OPENAI_API_KEY is set" do
      ENV["OPENAI_API_KEY"] = "test-key"
      provider = Grafito::AI::Providers::OpenAICompatible.new
      provider.available?.should be_true
    end

    it "returns true when GROQ_API_KEY is set" do
      ENV["GROQ_API_KEY"] = "test-key"
      provider = Grafito::AI::Providers::OpenAICompatible.new
      provider.available?.should be_true
    end

    it "returns true when TOGETHER_API_KEY is set" do
      ENV["TOGETHER_API_KEY"] = "test-key"
      provider = Grafito::AI::Providers::OpenAICompatible.new
      provider.available?.should be_true
    end

    it "returns true when GRAFITO_AI_ENDPOINT is set" do
      ENV["GRAFITO_AI_ENDPOINT"] = "http://localhost:11434"
      provider = Grafito::AI::Providers::OpenAICompatible.new
      provider.available?.should be_true
    end
  end

  describe "#complete" do
    before_each do
      WebMock.reset
      ENV["Z_AI_API_KEY"] = nil
      ENV["OPENAI_API_KEY"] = nil
      ENV["GROQ_API_KEY"] = nil
      ENV["TOGETHER_API_KEY"] = nil
      ENV["GRAFITO_AI_API_KEY"] = nil
      ENV["GRAFITO_AI_ENDPOINT"] = nil
      ENV["GRAFITO_AI_MODEL"] = nil
    end

    it "returns a response with content from the API" do
      ENV["Z_AI_API_KEY"] = "test-key"

      WebMock.stub(:post, "https://api.z.ai/api/paas/v4/chat/completions")
        .to_return(status: 200, body: {
          choices: [{message: {content: "This is a test response"}}],
          model:   "glm-4.5-flash",
          usage:   {prompt_tokens: 10, completion_tokens: 20},
        }.to_json)

      provider = Grafito::AI::Providers::OpenAICompatible.new
      request = Grafito::AI::Request.new(
        system_prompt: "You are helpful",
        user_prompt: "Hello"
      )

      response = provider.complete(request)
      response.content.should eq("This is a test response")
      response.model.should eq("glm-4.5-flash")
      response.provider.should eq("Z.AI")
    end

    it "parses usage statistics from the response" do
      ENV["OPENAI_API_KEY"] = "test-key"

      WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 200, body: {
          choices: [{message: {content: "Response"}}],
          model:   "gpt-4o-mini",
          usage:   {prompt_tokens: 50, completion_tokens: 100},
        }.to_json)

      provider = Grafito::AI::Providers::OpenAICompatible.new
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      response = provider.complete(request)
      response.usage.should_not be_nil
      response.usage.try(&.input_tokens).should eq(50)
      response.usage.try(&.output_tokens).should eq(100)
    end

    it "raises an error on API failure" do
      ENV["GROQ_API_KEY"] = "test-key"

      WebMock.stub(:post, "https://api.groq.com/openai/v1/chat/completions")
        .to_return(status: 401, body: {
          error: {message: "Invalid API key"},
        }.to_json)

      provider = Grafito::AI::Providers::OpenAICompatible.new
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      expect_raises(Exception, /API error/) do
        provider.complete(request)
      end
    end

    it "sends correct headers with API key" do
      ENV["OPENAI_API_KEY"] = "sk-test-key-123"

      WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
        .with(headers: {"Authorization" => "Bearer sk-test-key-123"})
        .to_return(status: 200, body: {
          choices: [{message: {content: "OK"}}],
          model:   "gpt-4o-mini",
        }.to_json)

      provider = Grafito::AI::Providers::OpenAICompatible.new
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      response = provider.complete(request)
      response.content.should eq("OK")
    end

    it "raises an error on malformed JSON response" do
      ENV["Z_AI_API_KEY"] = "test-key"

      WebMock.stub(:post, "https://api.z.ai/api/paas/v4/chat/completions")
        .to_return(status: 200, body: "not valid json{{{")

      provider = Grafito::AI::Providers::OpenAICompatible.new
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      expect_raises(Exception, /malformed JSON/) do
        provider.complete(request)
      end
    end

    it "raises an error when content field is missing" do
      ENV["Z_AI_API_KEY"] = "test-key"

      WebMock.stub(:post, "https://api.z.ai/api/paas/v4/chat/completions")
        .to_return(status: 200, body: {
          choices: [{message: {role: "assistant"}}],
          model:   "glm-4.5-flash",
        }.to_json)

      provider = Grafito::AI::Providers::OpenAICompatible.new
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      expect_raises(Exception, /missing content/) do
        provider.complete(request)
      end
    end

    it "raises an error when content is empty" do
      ENV["Z_AI_API_KEY"] = "test-key"

      WebMock.stub(:post, "https://api.z.ai/api/paas/v4/chat/completions")
        .to_return(status: 200, body: {
          choices: [{message: {content: ""}}],
          model:   "glm-4.5-flash",
        }.to_json)

      provider = Grafito::AI::Providers::OpenAICompatible.new
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      expect_raises(Exception, /empty response/) do
        provider.complete(request)
      end
    end

    it "raises an error when choices array is missing" do
      ENV["Z_AI_API_KEY"] = "test-key"

      WebMock.stub(:post, "https://api.z.ai/api/paas/v4/chat/completions")
        .to_return(status: 200, body: {
          model: "glm-4.5-flash",
        }.to_json)

      provider = Grafito::AI::Providers::OpenAICompatible.new
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      expect_raises(Exception, /missing content/) do
        provider.complete(request)
      end
    end
  end
end
