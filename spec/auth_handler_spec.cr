require "./spec_helper"
require "base64"

# AuthHandler specs: the handler is exercised directly (chained to a
# terminal handler that records the pass-through), because route specs
# dispatch through the route handler only.
# A terminal handler that flips a flag instead of routing.
class PassMarker
  include HTTP::Handler

  property? passed = false

  def call(context : HTTP::Server::Context) : Nil
    @passed = true
    context.response.status_code = 200
  end
end

def basic_header(user : String, password : String) : HTTP::Headers
  HTTP::Headers{"Authorization" => "Basic #{Base64.strict_encode("#{user}:#{password}")}"}
end

# Sends a GET through handler -> marker and reports the response
# status and whether the request passed through.
def through(handler : AuthHandler, headers : HTTP::Headers = HTTP::Headers.new) : {Int32, Bool, HTTP::Headers}
  marker = PassMarker.new
  handler.next = marker
  request = HTTP::Request.new("GET", "/server-info", headers)
  response_io = IO::Memory.new
  response = HTTP::Server::Response.new(response_io)
  context = HTTP::Server::Context.new(request, response)
  handler.call(context)
  response.close
  {response.status_code, marker.passed?, response.headers}
end

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

{% unless flag?(:demo_mode) %}
  # The handler resolves credentials through the real settings store;
  # demo builds keep it in memory.
  describe AuthHandler do
    it "passes everything through when no credentials exist anywhere" do
      data_dir = File.tempname("grafito-auth", "")
      Dir.mkdir(data_dir)
      begin
        with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
          old_data_dir = Grafito.data_dir
          Grafito.data_dir = data_dir
          begin
            status, passed, _ = through(AuthHandler.new)
            passed.should be_true
            status.should eq(200)
          ensure
            Grafito.data_dir = old_data_dir
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "challenges and admits against settings credentials" do
      data_dir = File.tempname("grafito-auth", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(auth_user: "admin", auth_pass: "se:cret"))
        with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
          old_data_dir = Grafito.data_dir
          Grafito.data_dir = data_dir
          begin
            handler = AuthHandler.new

            status, passed, headers = through(handler)
            passed.should be_false
            status.should eq(401)
            headers["WWW-Authenticate"].should contain("Basic realm=")

            status, passed, _ = through(handler, basic_header("admin", "wrong"))
            passed.should be_false
            status.should eq(401)

            # Passwords containing colons survive the first-colon split.
            status, passed, _ = through(handler, basic_header("admin", "se:cret"))
            passed.should be_true
            status.should eq(200)
          ensure
            Grafito.data_dir = old_data_dir
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
        SettingsStore.save(data_dir, SettingsStore::Settings.new(auth_user: "file-user", auth_pass: "file-pass"))
        with_env({"GRAFITO_AUTH_USER" => "env-user", "GRAFITO_AUTH_PASS" => "env-pass"}) do
          old_data_dir = Grafito.data_dir
          Grafito.data_dir = data_dir
          begin
            handler = AuthHandler.new
            _, passed, _ = through(handler, basic_header("file-user", "file-pass"))
            passed.should be_false

            _, passed, _ = through(handler, basic_header("env-user", "env-pass"))
            passed.should be_true
          ensure
            Grafito.data_dir = old_data_dir
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "rejects malformed Authorization headers" do
      data_dir = File.tempname("grafito-auth", "")
      Dir.mkdir(data_dir)
      begin
        SettingsStore.save(data_dir, SettingsStore::Settings.new(auth_user: "admin", auth_pass: "secret"))
        with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
          old_data_dir = Grafito.data_dir
          Grafito.data_dir = data_dir
          begin
            handler = AuthHandler.new
            _, passed, _ = through(handler, HTTP::Headers{"Authorization" => "Bearer nope"})
            passed.should be_false

            _, passed, _ = through(handler, HTTP::Headers{"Authorization" => "Basic %%%%"})
            passed.should be_false

            # A header without any colon in the decoded payload.
            _, passed, _ = through(handler, HTTP::Headers{"Authorization" => "Basic #{Base64.strict_encode("nocolon")}"})
            passed.should be_false
          ensure
            Grafito.data_dir = old_data_dir
          end
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end
  end
{% end %}
