require "../spec_helper"
require "../../src/ai/response"

describe Grafito::AI::Usage do
  it "calculates total tokens" do
    usage = Grafito::AI::Usage.new(
      input_tokens: 100,
      output_tokens: 50
    )

    usage.total_tokens.should eq(150)
  end

  it "serializes to JSON" do
    usage = Grafito::AI::Usage.new(
      input_tokens: 10,
      output_tokens: 20
    )

    json = usage.to_json
    json.should contain("\"input_tokens\":10")
    json.should contain("\"output_tokens\":20")
    # total_tokens is a computed method, not serialized
  end
end

describe Grafito::AI::Response do
  it "creates a response with all fields" do
    usage = Grafito::AI::Usage.new(10, 20)
    response = Grafito::AI::Response.new(
      content: "Hello, world!",
      model: "test-model",
      provider: "test-provider",
      usage: usage,
      raw: "{}"
    )

    response.content.should eq("Hello, world!")
    response.model.should eq("test-model")
    response.provider.should eq("test-provider")
    response.usage.should eq(usage)
    response.raw.should eq("{}")
  end

  it "handles nil optional fields" do
    response = Grafito::AI::Response.new(
      content: "Hello",
      model: "model",
      provider: "provider"
    )

    response.usage.should be_nil
    response.raw.should be_nil
  end

  describe "#empty?" do
    it "returns true for empty content" do
      response = Grafito::AI::Response.new(
        content: "",
        model: "model",
        provider: "provider"
      )

      response.empty?.should be_true
    end

    it "returns true for blank content" do
      response = Grafito::AI::Response.new(
        content: "   ",
        model: "model",
        provider: "provider"
      )

      response.empty?.should be_true
    end

    it "returns false for non-blank content" do
      response = Grafito::AI::Response.new(
        content: "Hello",
        model: "model",
        provider: "provider"
      )

      response.empty?.should be_false
    end
  end

  it "serializes to JSON without raw field" do
    response = Grafito::AI::Response.new(
      content: "Hello",
      model: "model",
      provider: "provider",
      raw: "should not appear"
    )

    json = response.to_json
    json.should contain("\"content\":\"Hello\"")
    json.should contain("\"model\":\"model\"")
    json.should contain("\"provider\":\"provider\"")
    json.should_not contain("should not appear")
  end
end
