require "./spec_helper"

# Route-level specs. These dispatch requests through Kemal's route handler
# directly (no socket, no middleware), so basic auth does not interfere.
describe "Kemal routes" do
  it "GET /command returns the equivalent journalctl command" do
    response = dispatch_request("GET", "/command?since=-1h&unit=nginx.service&q=error")

    response[:status].should eq(200)
    response[:body].should contain("journalctl")
    response[:body].should contain("-u nginx.service")
    response[:body].should contain("-g error")
  end

  it "GET /details returns 400 when the cursor parameter is missing" do
    response = dispatch_request("GET", "/details")

    response[:status].should eq(400)
    response[:body].should contain("Missing cursor")
  end

  it "GET /context returns 400 when the cursor parameter is missing" do
    response = dispatch_request("GET", "/context")

    response[:status].should eq(400)
    response[:body].should contain("Missing cursor")
  end

  it "GET /context returns 400 for a non-positive count" do
    response = dispatch_request("GET", "/context?cursor=abc&count=0")

    response[:status].should eq(400)
    response[:body].should contain("count must be positive")
  end

  it "POST /ask-ai returns 503 when no AI provider is configured" do
    Grafito.ai_provider = nil
    response = dispatch_request("POST", "/ask-ai", body: %({"cursor": "abc"}))

    response[:status].should eq(503)
    response[:body].should contain("AI features are disabled")
  end

  it "POST /ask-ai returns 400 when the cursor is missing" do
    Grafito.ai_provider = FakeAIProvider.new
    response = dispatch_request("POST", "/ask-ai", body: "{}")

    response[:status].should eq(400)
    response[:body].should contain("Missing 'cursor' parameter")
    Grafito.ai_provider = nil
  end

  it "GET /logs returns an empty state for a unit that has no entries" do
    response = dispatch_request("GET", "/logs?unit=grafito-no-such-unit-xyz&format=text")

    response[:status].should eq(200)
    response[:body].should contain("No log entries found.")
  end

  it "GET /ai-providers returns JSON with the expected shape" do
    response = dispatch_request("GET", "/ai-providers")

    response[:status].should eq(200)
    response[:body].should contain("\"providers\":")
    response[:body].should contain("\"enabled\":")
    response[:body].should contain("\"current\":")
  end
end
