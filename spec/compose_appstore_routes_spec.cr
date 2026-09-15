require "./spec_helper"

# Route-level specs for the app store endpoints. These dispatch
# requests through Kemal's route handler directly (like
# compose_routes_spec.cr) and use the fake store data, so they only
# make sense with -Ddemo_mode.
{% if flag?(:demo_mode) %}
  FORM_HEADERS = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}

  describe "Kemal app store routes" do
    it "GET /compose-appstore renders the catalog with fake apps" do
      Grafito.compose_enabled = true
      Grafito.apps_enabled = true
      response = dispatch_request("GET", "/compose-appstore")

      response[:status].should eq(200)
      response[:body].should contain("App store")
      response[:body].should contain("Whoami")
      response[:body].should contain("Jellyfin")
      response[:body].should_not contain("Retired App")
    end

    it "the catalog filters by search and category" do
      response = dispatch_request("GET", "/compose-appstore?q=jelly")
      response[:body].should contain("Jellyfin")
      response[:body].should_not contain("Whoami")

      response = dispatch_request("GET", "/compose-appstore?category=media")
      response[:body].should contain("Jellyfin")
      response[:body].should_not contain("File Browser")
    end

    it "app store GET endpoints return 404 when disabled" do
      Grafito.apps_enabled = false
      dispatch_request("GET", "/compose-appstore")[:status].should eq(404)
      dispatch_request("GET", "/compose-appstore-app?store=demo&app=jellyfin")[:status].should eq(404)

      Grafito.apps_enabled = true
      Grafito.compose_enabled = false
      dispatch_request("GET", "/compose-appstore")[:status].should eq(404)
      Grafito.compose_enabled = true
    end

    it "POST endpoints are gated by enable-actions + auth" do
      Grafito.enable_actions = false
      Grafito.auth_configured = false

      install_response = dispatch_request("POST", "/compose-appstore-install", "store=demo&app=jellyfin", FORM_HEADERS)
      install_response[:status].should eq(403)
      install_response[:body].should contain("disabled")

      dispatch_request("POST", "/compose-appstore-sync", "store=demo", FORM_HEADERS)[:status].should eq(403)
      dispatch_request("POST", "/compose-appstore-uninstall", "stack=webapp", FORM_HEADERS)[:status].should eq(403)
    end

    it "the install form validates ids and unknown apps" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      dispatch_request("GET", "/compose-appstore-app?store=-evil&app=whoami")[:status].should eq(400)
      dispatch_request("GET", "/compose-appstore-app?store=demo&app=no-such-app")[:status].should eq(404)

      response = dispatch_request("GET", "/compose-appstore-app?store=demo&app=jellyfin")
      response[:status].should eq(200)
      response[:body].should contain("Install Jellyfin")
    end

    it "installing starts a job and answers with its polling fragment" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      response = dispatch_request("POST", "/compose-appstore-install", "store=demo&app=jellyfin&port=8097", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-install-jellyfin")
      response[:body].should contain("data-job-running=")

      dispatch_request("POST", "/compose-appstore-install", "store=demo&app=-evil", FORM_HEADERS)[:status].should eq(400)
    end

    it "uninstall and update need an installed app" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      dispatch_request("POST", "/compose-appstore-uninstall", "stack=no-such-stack", FORM_HEADERS)[:status].should eq(404)
      dispatch_request("POST", "/compose-appstore-update", "stack=no-such-stack", FORM_HEADERS)[:status].should eq(404)

      response = dispatch_request("POST", "/compose-appstore-uninstall", "stack=webapp", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-uninstall-webapp")

      response = dispatch_request("POST", "/compose-appstore-update", "stack=webapp", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-update-webapp")

      Grafito.enable_actions = false
    end

    it "sync starts a job and the logo endpoint 404s without logos" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      response = dispatch_request("POST", "/compose-appstore-sync", "store=demo", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-sync")

      dispatch_request("POST", "/compose-appstore-sync", "store=nope", FORM_HEADERS)[:status].should eq(400)
      dispatch_request("GET", "/compose-appstore-logo?store=demo&app=jellyfin")[:status].should eq(404)
    end
  end
{% end %}
