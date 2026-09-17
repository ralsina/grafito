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

  it "GET /context clamps the count instead of running an unbounded query" do
    # A huge count used to reach journalctl verbatim (a memory/CPU
    # DoS); it now clamps to the same ceiling as /logs (500).
    response = dispatch_request("GET", "/context?cursor=abc&count=100000000")

    response[:status].should eq(200)
    {% if flag?(:demo_mode) %}
      # The fixture journal resolves the cursor and renders with the
      # clamped count.
      response[:body].should contain("Log Context (500 before")
    {% else %}
      response[:body].should contain("Could not retrieve context")
    {% end %}
  end

  it "POST /ask-ai returns 400 for malformed JSON" do
    Grafito.ai_provider = nil
    response = dispatch_request("POST", "/ask-ai", body: "{nope")

    response[:status].should eq(400)
    response[:body].should contain("Invalid JSON in request body")
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

  it "GET /server-info reports the demo flag matching the build" do
    response = dispatch_request("GET", "/server-info")

    response[:status].should eq(200)
    {% if flag?(:demo_mode) %}
      response[:body].should contain(%("demo":true))
    {% else %}
      response[:body].should contain(%("demo":false))
    {% end %}
    # The enabled-views map drives the frontend's default landing
    # view (bare URL -> homepage when enabled).
    response[:body].should contain(%("homepage":true))
  end

  it "GET / serves the app shell with versioned asset URLs" do
    response = dispatch_request("GET", "/")

    response[:status].should eq(200)
    response[:body].should contain(%(app.min.js?v=#{Grafito::VERSION}))
    response[:body].should_not contain("%%VERSION%%")
  end

  describe "cross-site POST rejection" do
    it "rejects state-changing POSTs with a cross-site Sec-Fetch-Site" do
      headers = HTTP::Headers{"Sec-Fetch-Site" => "cross-site"}
      response = dispatch_request("POST", "/unit/nginx.service/stop", headers: headers)

      response[:status].should eq 403
      response[:body].should contain("Cross-site request rejected.")
    end

    it "rejects state-changing POSTs with a mismatched Origin" do
      headers = HTTP::Headers{
        "Origin" => "https://evil.example",
        "Host"   => "grafito.local",
      }
      response = dispatch_request("POST", "/unit/nginx.service/stop", headers: headers)

      response[:status].should eq 403
      response[:body].should contain("Cross-site request rejected.")
    end

    it "allows same-origin and header-less POSTs through the gate" do
      headers = HTTP::Headers{"Sec-Fetch-Site" => "same-origin"}
      response = dispatch_request("POST", "/unit/nginx.service/stop", headers: headers)

      # The CSRF gate passes; the request then reaches the action
      # handling: a simulated action on demo builds, the actions gate
      # (403, actions disabled in specs) on real deployments.
      response[:body].should_not contain("Cross-site request rejected.")
      {% if flag?(:demo_mode) %}
        response[:status].should eq 200
      {% else %}
        response[:status].should eq 403
      {% end %}
    end
  end

  {% unless flag?(:demo_mode) %}
    it "GET /logs returns an empty state for a unit that has no entries" do
      response = dispatch_request("GET", "/logs?unit=grafito-no-such-unit-xyz&format=text")

      response[:status].should eq(200)
      response[:body].should contain("No log entries found.")
    end
  {% end %}

  it "GET /ai-providers returns JSON with the expected shape" do
    response = dispatch_request("GET", "/ai-providers")

    response[:status].should eq(200)
    response[:body].should contain("\"providers\":")
    response[:body].should contain("\"enabled\":")
    response[:body].should contain("\"current\":")
  end

  it "GET /status returns a snapshot JSON payload" do
    response = dispatch_request("GET", "/status")

    response[:status].should eq(200)
    body = JSON.parse(response[:body])
    body["load1"].as_f?.should_not be_nil
    body["mem_used_pct"].as_f?.should_not be_nil
    body["disk_used_pct"].as_f?.should_not be_nil
    body["uptime_sec"].as_i?.should_not be_nil
    body["units"].as_a?.should_not be_nil
    body["errors_last_hour"].as_i?.should_not be_nil
  end

  it "GET /status/history returns a points array" do
    response = dispatch_request("GET", "/status/history?since=-1h")

    response[:status].should eq(200)
    JSON.parse(response[:body])["points"].as_a?.should_not be_nil
  end

  it "GET /status/history rejects an invalid since value" do
    response = dispatch_request("GET", "/status/history?since=yesterday")

    response[:status].should eq(400)
    response[:body].should contain("Invalid 'since'")
  end

  it "GET /status/history downsamples when max_points is given" do
    response = dispatch_request("GET", "/status/history?since=-1h&max_points=10")

    response[:status].should eq(200)
    JSON.parse(response[:body])["points"].as_a.size.should be <= 10
  end

  it "GET /status/history/export returns a CSV attachment" do
    response = dispatch_request("GET", "/status/history/export?since=-1h")

    response[:status].should eq(200)
    response[:headers]["Content-Type"].should contain("text/csv")
    response[:headers]["Content-Disposition"].should contain("attachment")
    response[:body].should start_with("ts,load1")
  end

  it "GET /dashboard returns the dashboard fragment" do
    response = dispatch_request("GET", "/dashboard")

    response[:status].should eq(200)
    response[:body].should contain("dashboard-grid")
    response[:body].should contain("Services")
  end

  it "GET /dashboard accepts sort parameters" do
    response = dispatch_request("GET", "/dashboard?sort_by=state&sort_order=desc")

    response[:status].should eq(200)
    response[:body].should contain("arrow_downward")
  end

  it "GET /dashboard accepts a time window parameter" do
    response = dispatch_request("GET", "/dashboard?since=-15m")

    response[:status].should eq(200)
    response[:body].should contain("Errors (15m)")
  end

  it "GET /dashboard falls back to the default window on bad since" do
    response = dispatch_request("GET", "/dashboard?since=yesterday")

    response[:status].should eq(200)
    response[:body].should contain("Errors (6h)")
  end

  it "GET /dashboard accepts a unit filter parameter" do
    response = dispatch_request("GET", "/dashboard?unit=grafito-no-such-unit-xyz")

    response[:status].should eq(200)
    response[:body].should contain("No units match the filter.")
  end

  it "GET /unit-details returns 400 without a name" do
    response = dispatch_request("GET", "/unit-details")

    response[:status].should eq(400)
    response[:body].should contain("unit name")
  end

  it "GET /unit-details returns 404 for an unknown unit" do
    response = dispatch_request("GET", "/unit-details?name=grafito-no-such-unit-xyz")

    response[:status].should eq(404)
    response[:body].should contain("not found")
  end

  it "GET /unit-details rejects names that look like flags" do
    response = dispatch_request("GET", "/unit-details?name=%2D%2Ddangerous")

    response[:status].should eq(400)
    response[:body].should contain("unit name")
  end

  it "GET /unit-details renders the service panel fragment" do
    # Uses the real unit list (plain mode) or the fake one (-Ddemo_mode);
    # both include at least one unit, but the name is unknown here, so
    # just assert a valid unit renders its "View logs" call.
    units = SystemStatus.snapshot.units
    next if units.empty?

    response = dispatch_request("GET", "/unit-details?name=#{URI.encode_path(units.first.unit)}")
    response[:status].should eq(200)
    response[:body].should contain("service-panel")
    response[:body].should contain("View logs for this unit")
  end

  it "GET /status and /dashboard return 404 when the dashboard is disabled" do
    Grafito.dashboard_enabled = false
    begin
      dispatch_request("GET", "/status")[:status].should eq(404)
      dispatch_request("GET", "/dashboard")[:status].should eq(404)
    ensure
      Grafito.dashboard_enabled = true
    end
  end

  # Demo builds always simulate actions (see demo_actions_spec.cr);
  # real deployments gate them behind --enable-actions + auth.
  {% if !flag?(:demo_mode) %}
    it "POST unit actions returns 403 when actions are disabled" do
      Grafito.enable_actions = false
      begin
        response = dispatch_request("POST", "/unit/sshd/restart")
        response[:status].should eq(403)
        response[:body].should contain("Unit actions are disabled")
      ensure
        Grafito.enable_actions = false
      end
    end
  {% end %}

  it "POST unit actions returns 404 for a nonexistent unit" do
    Grafito.enable_actions = true
    Grafito.auth_configured = true
    begin
      response = dispatch_request("POST", "/unit/grafito-no-such-unit-xyz/restart")
      response[:status].should eq(404)
      response[:body].should contain("not found")
    ensure
      Grafito.enable_actions = false
    end
  end

  it "POST unit actions rejects an invalid action name" do
    Grafito.enable_actions = true
    Grafito.auth_configured = true
    begin
      response = dispatch_request("POST", "/unit/sshd/format")
      response[:status].should eq(400)
      response[:body].should contain("Invalid action")
    ensure
      Grafito.enable_actions = false
    end
  end

  it "POST unit actions rejects unit names that look like flags" do
    Grafito.enable_actions = true
    Grafito.auth_configured = true
    begin
      response = dispatch_request("POST", "/unit/%2D%2Ddangerous/restart")
      response[:status].should eq(400)
      response[:body].should contain("Invalid unit name")
    ensure
      Grafito.enable_actions = false
    end
  end
end

it "POST /unit-explain returns 503 without an AI provider" do
  Grafito.ai_provider = nil
  response = dispatch_request("POST", "/unit-explain?name=sshd.service")

  response[:status].should eq(503)
  response[:body].should contain("AI features are disabled")
end

it "POST /unit-explain returns 400 without a name" do
  Grafito.ai_provider = FakeAIProvider.new
  begin
    response = dispatch_request("POST", "/unit-explain")
    response[:status].should eq(400)
    response[:body].should contain("unit name")
  ensure
    Grafito.ai_provider = nil
  end
end

it "POST /unit-explain returns 404 for an unknown unit" do
  Grafito.ai_provider = FakeAIProvider.new
  begin
    response = dispatch_request("POST", "/unit-explain?name=grafito-no-such-unit-xyz")
    response[:status].should eq(404)
    response[:body].should contain("not found")
  ensure
    Grafito.ai_provider = nil
  end
end

it "POST /unit-explain returns an AI explanation fragment" do
  Grafito.ai_provider = FakeAIProvider.new
  units = SystemStatus.snapshot.units
  next if units.empty?

  begin
    response = dispatch_request("POST", "/unit-explain?name=#{URI.encode_path(units.first.unit)}")
    response[:status].should eq(200)
    response[:body].should contain("service-ai-answer")
    response[:body].should contain("fake explanation")
  ensure
    Grafito.ai_provider = nil
  end
end
