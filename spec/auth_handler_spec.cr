require "./spec_helper"

# AuthHandler specs: the handler is exercised directly (chained to a
# terminal PassMarker, see spec_helper), because route specs dispatch
# through the route handler only. Sessions are exercised by planting a
# real kemal-session on a first context and replaying its cookie,
# mirroring what a browser keeps between requests.

def with_env(pairs : Hash(String, String?), &)
  saved = {} of String => String?
  pairs.each do |key, value|
    saved[key] = ENV[key]?
    if value
      ENV[key] = value
    else
      ENV.delete(key)
    end
  end
  yield
ensure
  if saved
    saved.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end
end

# Points the settings store at a throwaway data dir (or back).
def with_auth_data_dir(data_dir : String, &)
  old_data_dir = Grafito.data_dir
  Grafito.data_dir = data_dir
  yield
ensure
  Grafito.data_dir = old_data_dir if old_data_dir
end

# Sends a request through handler -> marker and reports the response
# status, whether the request passed through, and the headers.
def through(handler : AuthHandler, headers : HTTP::Headers = HTTP::Headers.new,
            method : String = "GET", path : String = "/server-info")
  marker = PassMarker.new
  handler.next = marker
  request = HTTP::Request.new(method, path, headers)
  response_io = IO::Memory.new
  response = HTTP::Server::Response.new(response_io)
  context = HTTP::Server::Context.new(request, response)
  handler.call(context)
  response.close
  {response.status_code, marker.passed?, response.headers}
end

# Signs in on a throwaway context (against the given username) and
# returns the Cookie header a browser would replay afterwards.
def plant_session(user : String) : HTTP::Headers
  request = HTTP::Request.new("GET", "/login")
  response_io = IO::Memory.new
  response = HTTP::Server::Response.new(response_io)
  context = HTTP::Server::Context.new(request, response)
  context.session.string("user", user)
  response.close
  cookie = response.cookies[Kemal::Session.config.cookie_name]
  HTTP::Headers{"Cookie" => "#{cookie.name}=#{cookie.value}"}
end

{% unless flag?(:demo_mode) %}
  # The handler resolves credentials through the real settings store;
  # demo builds keep it in memory.
  describe AuthHandler do
    it "passes everything through when no credentials exist anywhere" do
      data_dir = File.tempname("grafito-auth", "")
      Dir.mkdir(data_dir)
      begin
        with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
          with_auth_data_dir(data_dir) do
            status, passed, _ = through(AuthHandler.new)
            passed.should be_true
            status.should eq(200)
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "redirects browsers to the login page without a session" do
      data_dir = File.tempname("grafito-auth", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(
          auth_user: "admin", auth_pass: SettingsStore.hash_password("secret")))
        with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
          with_auth_data_dir(data_dir) do
            handler = AuthHandler.new

            # Browser navigation.
            status, passed, headers = through(handler,
              HTTP::Headers{"Accept" => "text/html,application/xhtml+xml"})
            passed.should be_false
            status.should eq(302)
            headers["Location"].should eq("/login")

            # htmx: a 401 that the frontend turns into a full redirect.
            status, passed, headers = through(handler,
              HTTP::Headers{"HX-Request" => "true", "Accept" => "text/html"})
            passed.should be_false
            status.should eq(401)
            headers["HX-Redirect"].should eq("/login")

            # Anything else (curl, API clients).
            status, passed, _ = through(handler)
            passed.should be_false
            status.should eq(401)
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "admits a valid session cookie" do
      data_dir = File.tempname("grafito-auth", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(
          auth_user: "admin", auth_pass: SettingsStore.hash_password("secret")))
        with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
          with_auth_data_dir(data_dir) do
            handler = AuthHandler.new
            cookie = plant_session("admin")

            status, passed, _ = through(handler, cookie)
            passed.should be_true
            status.should eq(200)

            # A session for a different (stale) username is not valid:
            # renaming the user invalidates outstanding sessions.
            other = plant_session("former-user")
            status, passed, _ = through(handler, other)
            passed.should be_false
            status.should eq(401)
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "ignores Authorization headers entirely (basic auth is gone)" do
      data_dir = File.tempname("grafito-auth", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(
          auth_user: "admin", auth_pass: SettingsStore.hash_password("secret")))
        with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
          with_auth_data_dir(data_dir) do
            handler = AuthHandler.new
            basic = "Basic #{Base64.strict_encode("admin:secret")}"

            status, passed, headers = through(handler,
              HTTP::Headers{"Authorization" => basic, "Accept" => "text/html"})
            passed.should be_false
            status.should eq(302)
            headers["WWW-Authenticate"]?.should be_nil
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "lets the login page and its stylesheet through without a session" do
      data_dir = File.tempname("grafito-auth", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(
          auth_user: "admin", auth_pass: SettingsStore.hash_password("secret")))
        with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
          with_auth_data_dir(data_dir) do
            handler = AuthHandler.new

            {"/login", "/logout", "/pico.min.css"}.each do |path|
              status, passed, _ = through(handler, HTTP::Headers.new, path: path)
              passed.should be_true
              status.should eq(200)
            end

            # Everything else stays closed.
            status, passed, _ = through(handler, HTTP::Headers.new, path: "/style.css")
            passed.should be_false
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "prefers environment credentials over the settings file" do
      data_dir = File.tempname("grafito-auth", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(
          auth_user: "file-user", auth_pass: SettingsStore.hash_password("file-pass")))
        with_env({"GRAFITO_AUTH_USER" => "env-user", "GRAFITO_AUTH_PASS" => "env-pass"}) do
          with_auth_data_dir(data_dir) do
            handler = AuthHandler.new

            _, passed, _ = through(handler, plant_session("file-user"))
            passed.should be_false

            _, passed, _ = through(handler, plant_session("env-user"))
            passed.should be_true
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end
  end
{% end %}
