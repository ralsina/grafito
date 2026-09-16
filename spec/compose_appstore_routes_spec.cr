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

    it "POST endpoints simulate without enable-actions or auth" do
      Grafito.enable_actions = false
      Grafito.auth_configured = false

      response = dispatch_request("POST", "/compose-appstore-sync", "store=demo", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-sync")
    ensure
      FakeAppStore.reset_demo_state
      FakeComposeData.reset_demo_state
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

    it "installing starts a job, adds the app and its stack, and answers with the polling fragment" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      response = dispatch_request("POST", "/compose-appstore-install", "store=demo&app=jellyfin&port=8097", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-install-jellyfin")
      response[:body].should contain("data-job-running=")

      # The fake world now has the app installed and its stack running.
      FakeAppStore.find_installed("jellyfin").should_not be_nil
      ComposeStatus.stacks.find(&.name.==("jellyfin")).should_not be_nil

      # A second install of the same app is rejected.
      dispatch_request("POST", "/compose-appstore-install", "store=demo&app=jellyfin", FORM_HEADERS)[:status].should eq(409)

      dispatch_request("POST", "/compose-appstore-install", "store=demo&app=-evil", FORM_HEADERS)[:status].should eq(400)
    ensure
      FakeAppStore.reset_demo_state
      FakeComposeData.reset_demo_state
    end

    it "uninstall and update operate on the installed list" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      dispatch_request("POST", "/compose-appstore-uninstall", "stack=no-such-stack", FORM_HEADERS)[:status].should eq(404)
      dispatch_request("POST", "/compose-appstore-update", "stack=no-such-stack", FORM_HEADERS)[:status].should eq(404)

      # Install filebrowser, update the fixture app (its update badge
      # clears), then uninstall filebrowser again.
      dispatch_request("POST", "/compose-appstore-install", "store=demo&app=filebrowser", FORM_HEADERS)[:status].should eq(200)
      FakeAppStore.find_installed("filebrowser").should_not be_nil

      response = dispatch_request("POST", "/compose-appstore-update", "stack=webapp", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-update-webapp")
      updated = FakeAppStore.find_installed("webapp")
      updated.should_not be_nil
      if record = updated
        FakeAppStore.update_available(record).should be_nil
      end

      response = dispatch_request("POST", "/compose-appstore-uninstall", "stack=filebrowser", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-uninstall-filebrowser")
      FakeAppStore.find_installed("filebrowser").should be_nil
    ensure
      FakeAppStore.reset_demo_state
      FakeComposeData.reset_demo_state
    end

    it "uninstalling the fixture app keeps the fixture stack scenery" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      response = dispatch_request("POST", "/compose-appstore-uninstall", "stack=webapp", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-uninstall-webapp")

      # The badge and buttons are gone, but the seeded webapp stack
      # with its services is still part of the demo scenery.
      FakeAppStore.find_installed("webapp").should be_nil
      ComposeStatus.stacks.find(&.name.==("webapp")).should_not be_nil
    ensure
      FakeAppStore.reset_demo_state
      FakeComposeData.reset_demo_state
    end

    it "sync starts a job and the logo endpoint serves generated svgs" do
      Grafito.enable_actions = true
      Grafito.auth_configured = true

      response = dispatch_request("POST", "/compose-appstore-sync", "store=demo", FORM_HEADERS)
      response[:status].should eq(200)
      response[:body].should contain("appstore-sync")

      dispatch_request("POST", "/compose-appstore-sync", "store=nope", FORM_HEADERS)[:status].should eq(400)
      logo = dispatch_request("GET", "/compose-appstore-logo?store=demo&app=jellyfin")
      logo[:status].should eq(200)
      logo[:body].should contain("<svg")
      logo[:body].should contain(">J<")
      # Unknown fixture ids still get a generated logo, keyed by the id.
      dispatch_request("GET", "/compose-appstore-logo?store=demo&app=nope")[:status].should eq(200)
    end
  end
{% end %}
