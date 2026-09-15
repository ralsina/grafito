require "./spec_helper"

# Route-level specs for the compose view. These dispatch requests
# through Kemal's route handler directly (like routes_spec.cr), and use
# the fake compose data, so they only make sense with -Ddemo_mode.
{% if flag?(:demo_mode) %}
  describe "Kemal compose routes" do
    it "GET /compose renders the stack view" do
      Grafito.compose_enabled = true
      response = dispatch_request("GET", "/compose")

      response[:status].should eq(200)
      response[:body].should contain("webapp")
    end

    it "compose endpoints return 404 when the view is disabled" do
      Grafito.compose_enabled = false
      response = dispatch_request("GET", "/compose")
      response[:status].should eq(404)
      Grafito.compose_enabled = true
    end

    it "action endpoints are gated by enable-actions + auth" do
      Grafito.enable_actions = false
      Grafito.auth_configured = false

      stack_response = dispatch_request("POST", "/compose-stack/webapp/stop")
      stack_response[:status].should eq(403)
      stack_response[:body].should contain("Compose actions are disabled")

      service_response = dispatch_request("POST", "/compose-service/webapp/api/stop")
      service_response[:status].should eq(403)
    end

    it "action endpoints reject unknown actions and names" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      dispatch_request("POST", "/compose-stack/webapp/destroy")[:status].should eq(400)
      dispatch_request("POST", "/compose-stack/-evil/up")[:status].should eq(400)
      dispatch_request("POST", "/compose-stack/no-such-stack/up")[:status].should eq(404)
      dispatch_request("POST", "/compose-service/webapp/-evil/stop")[:status].should eq(400)
      dispatch_request("POST", "/compose-service/webapp/no-such-service/stop")[:status].should eq(404)

      Grafito.enable_actions = false
    end

    it "stack actions start a job and return its polling fragment" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      response = dispatch_request("POST", "/compose-stack/webapp/update")
      response[:status].should eq(200)
      response[:body].should contain("compose-output-webapp")
      response[:body].should contain("data-job-running=")

      Grafito.enable_actions = false
    end

    it "the job output endpoint reports unknown jobs" do
      response = dispatch_request("GET", "/compose-output/does-not-exist")
      response[:status].should eq(404)
      response[:body].should contain("Unknown compose job")
    end

    it "GET /compose-yaml serves the fake stack's compose file" do
      response = dispatch_request("GET", "/compose-yaml?stack=webapp")
      response[:status].should eq(200)
      response[:body].should contain("services:")
    end

    it "GET /compose-logs serves a pollable log tail" do
      response = dispatch_request("GET", "/compose-logs?stack=webapp&service=web")
      response[:status].should eq(200)
      response[:body].should contain("every 5s")
    end

    it "GET /compose-details rejects invalid names" do
      dispatch_request("GET", "/compose-details?stack=-evil&service=web")[:status].should eq(400)
      dispatch_request("GET", "/compose-details?stack=webapp&service=nope")[:status].should eq(404)
    end
  end
{% end %}
