require "./spec_helper"

# Settings view route specs: fragment shapes, the auth gates, the
# onboarding lifecycle and validation errors. Requests dispatch
# through the route handler only; auth is unit-tested in
# auth_handler_spec, so these specs control `auth_configured?` via
# the environment.
def with_settings_env(data_dir : String, auth : Bool, &)
  previous_user = ENV["GRAFITO_AUTH_USER"]?
  previous_pass = ENV["GRAFITO_AUTH_PASS"]?
  old_data_dir = Grafito.data_dir
  old_homepage_config = Grafito.homepage_config_path
  old_timezone = Grafito.timezone
  begin
    Grafito.data_dir = data_dir
    Grafito.homepage_config_path = File.join(data_dir, "missing-homepage.yml")
    if auth
      ENV["GRAFITO_AUTH_USER"] = "spec-user"
      ENV["GRAFITO_AUTH_PASS"] = "spec-pass"
    else
      ENV.delete("GRAFITO_AUTH_USER")
      ENV.delete("GRAFITO_AUTH_PASS")
    end
    yield
  ensure
    Grafito.data_dir = old_data_dir
    Grafito.homepage_config_path = old_homepage_config
    Grafito.timezone = old_timezone
    if previous_user
      ENV["GRAFITO_AUTH_USER"] = previous_user
    else
      ENV.delete("GRAFITO_AUTH_USER")
    end
    if previous_pass
      ENV["GRAFITO_AUTH_PASS"] = previous_pass
    else
      ENV.delete("GRAFITO_AUTH_PASS")
    end
  end
end

# Kemal only parses the request body into params.body when the
# request says it is a form (htmx does this automatically).
SETTINGS_FORM_HEADERS = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}

describe "Settings routes" do
  {% unless flag?(:demo_mode) %}
    # These exercise the onboarding lifecycle and settings
    # persistence; demo builds keep the store in memory and start
    # onboarded, so only the demo-specific save test below applies.
    it "GET /settings renders the wizard on a fresh instance" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: false) do
          response = dispatch_request("GET", "/settings")
          response[:status].should eq(200)
          response[:body].should contain("Welcome to grafito")
          response[:body].should contain("Create your login")
          response[:body].should contain("/settings/onboard")
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "GET /settings renders the form and env notice when auth comes from the environment" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: true) do
          response = dispatch_request("GET", "/settings")
          response[:status].should eq(200)
          response[:body].should contain("Settings")
          response[:body].should contain("GRAFITO_AUTH_USER")
          response[:body].should contain("/settings/save")
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "GET /settings is 404 when the view is disabled" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: true) do
          Grafito.settings_enabled = false
          begin
            response = dispatch_request("GET", "/settings")
            response[:status].should eq(404)
          ensure
            Grafito.settings_enabled = true
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "POST /settings/onboard creates the login and closes itself" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: false) do
          response = dispatch_request("POST", "/settings/onboard",
            body: "auth_user=admin&auth_pass=secret&auth_pass2=secret&timezone=UTC",
            headers: SETTINGS_FORM_HEADERS)
          response[:status].should eq(200)
          response[:body].should contain("Onboarding complete")

          settings = SettingsStore.load(data_dir)
          settings.auth_user.should eq("admin")
          # The password is stored as a bcrypt hash that verifies.
          SettingsStore.bcrypt_hash?(settings.auth_pass).should be_true
          Crypto::Bcrypt::Password.new(settings.auth_pass.to_s).verify("secret").should be_true
          settings.timezone.should eq("UTC")
          settings.onboarded?.should be_true
          Grafito.timezone.should eq("UTC")

          # The endpoint is closed forever now. The save endpoint is
          # open at the route level (credentials exist); blocking
          # unauthenticated requests is the auth handler's job, covered
          # in auth_handler_spec.
          closed = dispatch_request("POST", "/settings/onboard",
            body: "auth_user=other&auth_pass=aaaa&auth_pass2=aaaa",
            headers: SETTINGS_FORM_HEADERS)
          closed[:status].should eq(403)

          saved = dispatch_request("POST", "/settings/save", body: "timezone=UTC", headers: SETTINGS_FORM_HEADERS)
          saved[:status].should eq(200)
          saved[:body].should contain("Settings saved.")
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "POST /settings/onboard re-renders the wizard with errors and writes nothing" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: false) do
          response = dispatch_request("POST", "/settings/onboard",
            body: "auth_user=admin&auth_pass=secret&auth_pass2=other",
            headers: SETTINGS_FORM_HEADERS)
          response[:status].should eq(200)
          response[:body].should contain("Passwords do not match")
          response[:body].should contain("Create your login")
          File.exists?(SettingsStore.path(data_dir)).should be_false
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "POST /settings/save applies settings live when authenticated" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: true) do
          response = dispatch_request("POST", "/settings/save",
            body: "timezone=UTC&hp_title=My%20Lab&hp_hostname=rocky&hp_latitude=-34.6&hp_longitude=-58.38&hp_location=Buenos%20Aires",
            headers: SETTINGS_FORM_HEADERS)
          response[:status].should eq(200)
          response[:body].should contain("Settings saved.")

          settings = SettingsStore.load(data_dir)
          settings.timezone.should eq("UTC")
          Grafito.timezone.should eq("UTC")
          homepage = settings.homepage
          if homepage
            homepage.title.should eq("My Lab")
            homepage.hostname.should eq("rocky")
          else
            fail("homepage overlay should have been saved")
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "POST /settings/save rejects an unknown timezone and keeps the form values" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: true) do
          response = dispatch_request("POST", "/settings/save",
            body: "timezone=Not/AZone&hp_title=Kept",
            headers: SETTINGS_FORM_HEADERS)
          response[:status].should eq(200)
          response[:body].should contain("Unknown timezone")
          response[:body].should contain("Kept")
          SettingsStore.load(data_dir).timezone.should be_nil
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "POST /settings/save persists stacks dir, app stores and gotify, applying them live" do
      old_stacks_dir : String? = Grafito.stacks_dir
      old_appstores : String = Grafito.appstores_spec
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: true) do
          response = dispatch_request("POST", "/settings/save",
            body: "stacks_dir=/data/stacks&appstores=official%3Dhttps%3A%2F%2Fexample.com%2Fstore.tar.gz%0Aextra%3Dhttps%3A%2F%2Fother.example%2Fs.tar.gz&gotify_url=https%3A%2F%2Fpush.example.com&gotify_token=tk&gotify_priority=7&gotify_disk_pct=80",
            headers: SETTINGS_FORM_HEADERS)
          response[:status].should eq(200)
          response[:body].should contain("Settings saved.")

          settings = SettingsStore.load(data_dir)
          settings.stacks_dir.should eq("/data/stacks")
          Grafito.stacks_dir.should eq("/data/stacks")
          appstores = settings.appstores
          if appstores
            appstores.should contain("official=")
            appstores.should contain("extra=")
          else
            fail("app stores should have been saved")
          end
          Grafito.appstores_spec.should contain("official=")
          gotify = settings.gotify
          if gotify
            gotify.url.should eq("https://push.example.com")
            gotify.token.should eq("tk")
            gotify.priority.should eq(7)
            gotify.disk_pct.should eq(80.0)
          else
            fail("gotify settings should have been saved")
          end
        end
      ensure
        Grafito.stacks_dir = old_stacks_dir
        Grafito.appstores_spec = old_appstores
        FileUtils.rm_rf(data_dir)
      end
    end

    it "POST /settings/save rejects a malformed app store line" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: true) do
          response = dispatch_request("POST", "/settings/save",
            body: "appstores=not-a-pair",
            headers: SETTINGS_FORM_HEADERS)
          response[:status].should eq(200)
          response[:body].should contain("must be name=url")
          SettingsStore.load(data_dir).appstores.should be_nil
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "POST /settings/save rejects cross-site posts" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: true) do
          response = dispatch_request("POST", "/settings/save",
            body: "timezone=UTC",
            headers: HTTP::Headers{"Origin" => "https://evil.example", "Host" => "localhost:3000",
                                   "Content-Type" => "application/x-www-form-urlencoded"})
          response[:status].should eq(403)
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "server-info reports onboarding_needed only on a fresh instance" do
      data_dir = File.tempname("grafito-settings-routes", "")
      Dir.mkdir(data_dir)
      begin
        with_settings_env(data_dir, auth: false) do
          fresh = dispatch_request("GET", "/server-info")
          fresh[:body].should contain(%("onboarding_needed":true))
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end
  {% end %}

  {% if flag?(:demo_mode) %}
    it "settings save is simulated in demo mode" do
      FakeSettings.reset
      begin
        # Demo builds have no credentials; the save route allows them
        # anyway and simulates the change.
        response = dispatch_request("POST", "/settings/save",
          body: "timezone=UTC&hp_title=Demo%20Lab",
          headers: SETTINGS_FORM_HEADERS)
        response[:status].should eq(200)
        response[:body].should contain("Demo mode")
        FakeSettings.load.homepage.try(&.title).should eq("Demo Lab")
      ensure
        FakeSettings.reset
      end
    end
  {% end %}
end
