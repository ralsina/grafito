require "./spec_helper"

# Login and logout route specs. These dispatch through the route
# handler like other route specs; sessions are exercised by replaying
# the Set-Cookie value the login response produces, the way a browser
# would.

LOGIN_FORM_HEADERS = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}

CROSS_SITE_LOGIN_HEADERS = HTTP::Headers{
  "Content-Type"   => "application/x-www-form-urlencoded",
  "Sec-Fetch-Site" => "cross-site",
}

# A data dir + cleaned environment, with credentials from either the
# settings file (legacy plaintext or bcrypt) or the environment.
def with_login_env(data_dir : String, &)
  old_data_dir = Grafito.data_dir
  saved_user = ENV["GRAFITO_AUTH_USER"]?
  saved_pass = ENV["GRAFITO_AUTH_PASS"]?
  begin
    Grafito.data_dir = data_dir
    ENV.delete("GRAFITO_AUTH_USER")
    ENV.delete("GRAFITO_AUTH_PASS")
    yield
  ensure
    Grafito.data_dir = old_data_dir
    if saved_user
      ENV["GRAFITO_AUTH_USER"] = saved_user
    else
      ENV.delete("GRAFITO_AUTH_USER")
    end
    if saved_pass
      ENV["GRAFITO_AUTH_PASS"] = saved_pass
    else
      ENV.delete("GRAFITO_AUTH_PASS")
    end
  end
end

def post_login(username : String, password : String, headers = LOGIN_FORM_HEADERS)
  body = "username=#{URI.encode_www_form(username)}&password=#{URI.encode_www_form(password)}"
  dispatch_request("POST", "/login", body: body, headers: headers)
end

def session_cookie(response) : String?
  return unless set_cookie = response[:headers]["Set-Cookie"]?
  # "name=value; path=/..." → "name=value"
  pair = set_cookie.split(';').first?
  return unless pair && pair.includes?("=")
  pair
end

{% unless flag?(:demo_mode) %}
  describe "Login routes" do
    it "renders the sign-in page" do
      data_dir = File.tempname("grafito-login", "")
      Dir.mkdir(data_dir)
      begin
        with_login_env(data_dir) do
          response = dispatch_request("GET", "/login")
          response[:status].should eq(200)
          response[:body].should contain("Sign in")
          response[:body].should contain("pico.min.css")
          response[:body].should contain("login-username")
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "signs in against settings credentials and sets the session cookie" do
      data_dir = File.tempname("grafito-login", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(
          auth_user: "admin", auth_pass: SettingsStore.hash_password("secret")))
        with_login_env(data_dir) do
          response = post_login("admin", "secret")
          response[:status].should eq(302)
          response[:headers]["Location"].should eq("/")

          cookie = session_cookie(response)
          cookie.should_not be_nil
          if cookie
            cookie.should contain("grafito_session=")

            # The cookie authenticates against the auth handler.
            marker = PassMarker.new
            handler = AuthHandler.new
            handler.next = marker
            request = HTTP::Request.new("GET", "/server-info",
              HTTP::Headers{"Cookie" => cookie})
            response_io = IO::Memory.new
            server_response = HTTP::Server::Response.new(response_io)
            context = HTTP::Server::Context.new(request, server_response)
            handler.call(context)
            server_response.close
            marker.passed?.should be_true
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "rejects a wrong password without creating a session" do
      data_dir = File.tempname("grafito-login", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(
          auth_user: "admin", auth_pass: SettingsStore.hash_password("secret")))
        with_login_env(data_dir) do
          response = post_login("admin", "wrong")
          response[:status].should eq(401)
          response[:body].should contain("Wrong username or password")
          # The failed page echoes the username but not the password.
          response[:body].should contain(%(value="admin"))
          response[:body].should_not contain("wrong")
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "signs in against environment credentials" do
      data_dir = File.tempname("grafito-login", "")
      Dir.mkdir(data_dir)
      begin
        with_login_env(data_dir) do
          ENV["GRAFITO_AUTH_USER"] = "env-user"
          ENV["GRAFITO_AUTH_PASS"] = "env-pass"
          response = post_login("env-user", "env-pass")
          response[:status].should eq(302)
          cookie = session_cookie(response)
          cookie.should_not be_nil
          cookie.try(&.should(contain("grafito_session=")))
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "upgrades a legacy plaintext settings password to bcrypt on login" do
      data_dir = File.tempname("grafito-login", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(
          auth_user: "admin", auth_pass: "legacy-plain"))
        with_login_env(data_dir) do
          response = post_login("admin", "legacy-plain")
          response[:status].should eq(302)

          stored = SettingsStore.load(data_dir).auth_pass
          stored.should_not be_nil
          SettingsStore.bcrypt_hash?(stored).should be_true
          Crypto::Bcrypt::Password.new(stored.to_s).verify("legacy-plain").should be_true

          # And the plaintext no longer verifies directly.
          stored.should_not eq("legacy-plain")
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "destroys the session on logout" do
      data_dir = File.tempname("grafito-login", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(
          auth_user: "admin", auth_pass: SettingsStore.hash_password("secret")))
        with_login_env(data_dir) do
          login = post_login("admin", "secret")
          cookie = session_cookie(login)
          cookie.should_not be_nil

          if cookie
            logout = dispatch_request("POST", "/logout", headers: HTTP::Headers{"Cookie" => cookie})
            logout[:status].should eq(302)
            logout[:headers]["Location"].should eq("/login")

            # htmx callers get a 200 + HX-Redirect instead (a 302 would
            # be followed by the XHR itself).
            relogin = post_login("admin", "secret")
            if fresh = session_cookie(relogin)
              htmx_logout = dispatch_request("POST", "/logout",
                headers: HTTP::Headers{"Cookie" => fresh, "HX-Request" => "true"})
              htmx_logout[:status].should eq(200)
              htmx_logout[:headers]["HX-Redirect"].should eq("/login")
            end

            # The same cookie no longer authenticates: the server-side
            # session is gone.
            marker = PassMarker.new
            handler = AuthHandler.new
            handler.next = marker
            request = HTTP::Request.new("GET", "/server-info",
              HTTP::Headers{"Cookie" => cookie})
            response_io = IO::Memory.new
            server_response = HTTP::Server::Response.new(response_io)
            context = HTTP::Server::Context.new(request, server_response)
            handler.call(context)
            server_response.close
            marker.passed?.should be_false
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "rejects cross-site login posts" do
      data_dir = File.tempname("grafito-login", "")
      Dir.mkdir(data_dir)
      begin
        with_login_env(data_dir) do
          response = post_login("admin", "secret", headers: CROSS_SITE_LOGIN_HEADERS)
          response[:status].should eq(403)
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "mentions environment-managed credentials on the page" do
      data_dir = File.tempname("grafito-login", "")
      Dir.mkdir(data_dir)
      begin
        with_login_env(data_dir) do
          ENV["GRAFITO_AUTH_USER"] = "env-user"
          ENV["GRAFITO_AUTH_PASS"] = "env-pass"
          response = dispatch_request("GET", "/login")
          response[:body].should contain("managed by the environment")
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end
  end
{% end %}

{% if flag?(:demo_mode) %}
  describe "Login routes" do
    it "renders the sign-in page" do
      response = dispatch_request("GET", "/login")
      response[:status].should eq(200)
      response[:body].should contain("Sign in")
    end
  end
{% end %}
