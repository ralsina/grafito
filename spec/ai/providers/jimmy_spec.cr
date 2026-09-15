require "../../spec_helper"
require "../../../src/ai/providers/jimmy"

describe Grafito::AI::Providers::Jimmy do
  before_each do
    WebMock.reset
    ENV["GRAFITO_AI_PROVIDER"] = nil
    ENV["GRAFITO_AI_MODEL"] = nil
    ENV["GRAFITO_AI_TIMEOUT_SEC"] = nil
  end

  describe ".selects?" do
    it "accepts jimmy and chatjimmy" do
      Grafito::AI::Providers::Jimmy.selects?("jimmy").should be_true
      Grafito::AI::Providers::Jimmy.selects?("chatjimmy").should be_true
    end

    it "rejects other provider ids" do
      Grafito::AI::Providers::Jimmy.selects?("openai").should be_false
      Grafito::AI::Providers::Jimmy.selects?("anthropic").should be_false
      Grafito::AI::Providers::Jimmy.selects?("").should be_false
    end
  end

  describe ".available?" do
    it "is true when GRAFITO_AI_PROVIDER=jimmy" do
      ENV["GRAFITO_AI_PROVIDER"] = "jimmy"
      Grafito::AI::Providers::Jimmy.available?.should be_true
    end

    it "is true when GRAFITO_AI_PROVIDER=chatjimmy" do
      ENV["GRAFITO_AI_PROVIDER"] = "chatjimmy"
      Grafito::AI::Providers::Jimmy.available?.should be_true
    end

    it "normalizes case and whitespace" do
      ENV["GRAFITO_AI_PROVIDER"] = "  Jimmy "
      Grafito::AI::Providers::Jimmy.available?.should be_true
    end

    it "is false when GRAFITO_AI_PROVIDER names another provider" do
      ENV["GRAFITO_AI_PROVIDER"] = "openai"
      Grafito::AI::Providers::Jimmy.available?.should be_false
    end

    it "is false when GRAFITO_AI_PROVIDER is unset (never auto-detected)" do
      Grafito::AI::Providers::Jimmy.available?.should be_false
    end
  end

  describe "#name" do
    it "includes the model" do
      provider = Grafito::AI::Providers::Jimmy.new
      provider.name.should eq("ChatJimmy (llama3.1-8B)")
    end

    it "uses a model passed to the constructor" do
      provider = Grafito::AI::Providers::Jimmy.new("llama3.1-8B")
      provider.name.should eq("ChatJimmy (llama3.1-8B)")
    end

    it "respects GRAFITO_AI_MODEL" do
      ENV["GRAFITO_AI_MODEL"] = "custom-model"
      provider = Grafito::AI::Providers::Jimmy.new
      provider.name.should eq("ChatJimmy (custom-model)")
    end
  end

  describe "#current_model" do
    it "defaults to llama3.1-8B" do
      provider = Grafito::AI::Providers::Jimmy.new
      provider.current_model.should eq("llama3.1-8B")
    end

    it "uses a model passed to the constructor" do
      provider = Grafito::AI::Providers::Jimmy.new("other-model")
      provider.current_model.should eq("other-model")
    end
  end

  describe "#models" do
    it "returns the curated model list" do
      provider = Grafito::AI::Providers::Jimmy.new
      models = provider.models
      models.map(&.id).should eq(["llama3.1-8B"])
      models.first.name.should eq("Llama 3.1 8B")
      models.first.default.should be_true
    end
  end

  describe "#available?" do
    it "mirrors the class method" do
      ENV["GRAFITO_AI_PROVIDER"] = "jimmy"
      provider = Grafito::AI::Providers::Jimmy.new
      provider.available?.should be_true

      ENV["GRAFITO_AI_PROVIDER"] = nil
      provider.available?.should be_false
    end
  end

  describe "#complete" do
    it "posts the chatjimmy payload format and replays history" do
      received_body = nil
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .to_return do |request|
          received_body = JSON.parse(request.body || "{}")
          HTTP::Client::Response.new(status_code: 200, body: "Here is my analysis")
        end

      provider = Grafito::AI::Providers::Jimmy.new
      request = Grafito::AI::Request.new(
        system_prompt: "You are helpful",
        user_prompt: "Analyze this log",
        history: [
          {"role" => "assistant", "content" => "Previous answer"},
          {"role" => "user", "content" => "Latest question"},
        ]
      )

      response = provider.complete(request)
      response.content.should eq("Here is my analysis")

      body = received_body.should be_a(JSON::Any)
      body["chatOptions"]["selectedModel"].as_s.should eq("llama3.1-8B")
      body["chatOptions"]["systemPrompt"].as_s.should eq("You are helpful")
      body["attachment"].raw.should be_nil

      messages = body["messages"].as_a
      messages.size.should eq(3)
      messages[0]["role"].as_s.should eq("user")
      messages[0]["content"].as_s.should eq("Analyze this log")
      messages[1]["content"].as_s.should eq("Previous answer")
      messages[2]["content"].as_s.should eq("Latest question")
    end

    it "sends browser-like headers because the upstream is a web endpoint" do
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .with(headers: {
          "Origin"  => "https://chatjimmy.ai",
          "Referer" => "https://chatjimmy.ai/",
        })
        .to_return(status: 200, body: "ok")

      provider = Grafito::AI::Providers::Jimmy.new
      request = Grafito::AI::Request.new(system_prompt: "s", user_prompt: "u")
      response = provider.complete(request)
      response.content.should eq("ok")
    end

    it "uses the model override in the payload" do
      received_body = nil
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .to_return do |request|
          received_body = JSON.parse(request.body || "{}")
          HTTP::Client::Response.new(status_code: 200, body: "ok")
        end

      provider = Grafito::AI::Providers::Jimmy.new("llama3.1-8B")
      request = Grafito::AI::Request.new(system_prompt: "s", user_prompt: "u")
      provider.complete(request)

      body = received_body.should be_a(JSON::Any)
      body["chatOptions"]["selectedModel"].as_s.should eq("llama3.1-8B")
    end

    it "truncates oversized system prompts" do
      received_body = nil
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .to_return do |request|
          received_body = JSON.parse(request.body || "{}")
          HTTP::Client::Response.new(status_code: 200, body: "ok")
        end

      provider = Grafito::AI::Providers::Jimmy.new
      request = Grafito::AI::Request.new(system_prompt: "x" * 30000, user_prompt: "u")
      provider.complete(request)

      body = received_body.should be_a(JSON::Any)
      body["chatOptions"]["systemPrompt"].as_s.size
        .should eq(Grafito::AI::Providers::Jimmy::MAX_SYSTEM_PROMPT)
    end

    it "keeps system prompts within the limit untouched" do
      received_body = nil
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .to_return do |request|
          received_body = JSON.parse(request.body || "{}")
          HTTP::Client::Response.new(status_code: 200, body: "ok")
        end

      provider = Grafito::AI::Providers::Jimmy.new
      request = Grafito::AI::Request.new(system_prompt: "not truncated", user_prompt: "u")
      provider.complete(request)

      body = received_body.should be_a(JSON::Any)
      body["chatOptions"]["systemPrompt"].as_s.should eq("not truncated")
    end

    it "strips the stats block and parses token usage" do
      upstream_body = "Here is my analysis.\n" \
                      "<|stats|>{\"prefill_tokens\": 120, \"decode_tokens\": 80, \"total_tokens\": 200}<|/stats|>"
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .to_return(status: 200, body: upstream_body)

      provider = Grafito::AI::Providers::Jimmy.new
      request = Grafito::AI::Request.new(system_prompt: "s", user_prompt: "u")

      response = provider.complete(request)
      response.content.should eq("Here is my analysis.")
      response.provider.should eq("ChatJimmy")
      response.model.should eq("llama3.1-8B")
      response.usage.try(&.input_tokens).should eq(120)
      response.usage.try(&.output_tokens).should eq(80)
      response.usage.try(&.total_tokens).should eq(200)
    end

    it "handles a multiline stats block" do
      upstream_body = "Answer\n<|stats|>\n{\"prefill_tokens\": 5, \"decode_tokens\": 6}\n<|/stats|>\n"
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .to_return(status: 200, body: upstream_body)

      provider = Grafito::AI::Providers::Jimmy.new
      request = Grafito::AI::Request.new(system_prompt: "s", user_prompt: "u")

      response = provider.complete(request)
      response.content.should eq("Answer")
      response.usage.try(&.input_tokens).should eq(5)
      response.usage.try(&.output_tokens).should eq(6)
    end

    it "returns no usage when the stats block is missing" do
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .to_return(status: 200, body: "Plain answer")

      provider = Grafito::AI::Providers::Jimmy.new
      request = Grafito::AI::Request.new(system_prompt: "s", user_prompt: "u")

      response = provider.complete(request)
      response.content.should eq("Plain answer")
      response.usage.should be_nil
    end

    it "raises on a stats-only (empty) response" do
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .to_return(status: 200, body: "<|stats|>{\"prefill_tokens\": 1, \"decode_tokens\": 1}<|/stats|>")

      provider = Grafito::AI::Providers::Jimmy.new
      request = Grafito::AI::Request.new(system_prompt: "s", user_prompt: "u")

      expect_raises(Exception, /empty response/) do
        provider.complete(request)
      end
    end

    it "raises on HTTP errors" do
      WebMock.stub(:post, "https://chatjimmy.ai/api/chat")
        .to_return(status: 502, body: "Bad Gateway")

      provider = Grafito::AI::Providers::Jimmy.new
      request = Grafito::AI::Request.new(system_prompt: "s", user_prompt: "u")

      expect_raises(Exception, /API error/) do
        provider.complete(request)
      end
    end
  end
end

describe Grafito::AI::Config do
  after_each do
    ENV["GRAFITO_AI_PROVIDER"] = nil
  end

  describe "ProviderType" do
    it "converts Jimmy to string correctly" do
      Grafito::AI::Config::ProviderType::Jimmy.to_s.should eq("jimmy")
    end
  end

  describe "with GRAFITO_AI_PROVIDER=jimmy" do
    it "selects the jimmy provider type" do
      ENV["GRAFITO_AI_PROVIDER"] = "jimmy"
      Grafito::AI::Config.provider_type
        .should eq(Grafito::AI::Config::ProviderType::Jimmy)
    end

    it "accepts chatjimmy as an alias" do
      ENV["GRAFITO_AI_PROVIDER"] = "chatjimmy"
      Grafito::AI::Config.provider_type
        .should eq(Grafito::AI::Config::ProviderType::Jimmy)
    end

    it "builds a Jimmy provider from the flag" do
      ENV["GRAFITO_AI_PROVIDER"] = "jimmy"
      Grafito::AI::Config.provider.should be_a(Grafito::AI::Providers::Jimmy)
    end

    it "builds a Jimmy provider by id" do
      ENV["GRAFITO_AI_PROVIDER"] = "jimmy"
      Grafito::AI::Config.provider_by_id("jimmy")
        .should be_a(Grafito::AI::Providers::Jimmy)
    end

    it "lists ChatJimmy among the available providers" do
      ENV["GRAFITO_AI_PROVIDER"] = "jimmy"
      provider_ids = Grafito::AI::Config.available_providers.map(&.id)
      provider_ids.should contain("jimmy")
    end
  end

  describe "without the jimmy flag" do
    it "never auto-detects ChatJimmy" do
      ENV["GRAFITO_AI_PROVIDER"] = nil
      Grafito::AI::Config.provider_type
        .should_not eq(Grafito::AI::Config::ProviderType::Jimmy)
    end

    it "returns nil for provider_by_id(\"jimmy\")" do
      ENV["GRAFITO_AI_PROVIDER"] = nil
      Grafito::AI::Config.provider_by_id("jimmy").should be_nil
    end

    it "does not list ChatJimmy among the available providers" do
      ENV["GRAFITO_AI_PROVIDER"] = nil
      provider_ids = Grafito::AI::Config.available_providers.map(&.id)
      provider_ids.should_not contain("jimmy")
    end
  end
end
