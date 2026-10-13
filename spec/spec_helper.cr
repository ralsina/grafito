require "spec"
require "webmock"
require "file_utils"
require "../src/grafito"

# Dispatches an HTTP request through Kemal's route handler without binding
# a socket. Returns the response status code and body.
# Routes must be registered exactly once: Kemal raises when the same
# route path is added twice.
Grafito.register_routes

# The session endpoints read `env.session`, which signs the session-id
# cookie with the configured secret — materializing any session without
# this would raise. The app configures this in main.cr at boot; specs
# never run main, so it lives here instead. In-memory engine, fixed
# secret: hermetic and shared by every example.
Kemal::Session.config do |config|
  config.cookie_name = "grafito_session"
  config.secret = "spec-session-secret"
  config.timeout = 1.hour
  config.engine = Kemal::Session::MemoryEngine.new
end

# Many specs flip module-level switches (auth override, view enables,
# actions, the AI provider, the data dir...) and environment variables.
# `crystal spec` runs files in filesystem readdir order, which differs
# between machines, so a leaked value from one file can break another
# on some runners and not others. Snapshot the mutable global state
# (and the environment) around every example instead of trusting each
# spec file to clean up after itself.

# The mutable module-level state, as one value.
def snapshot_grafito_state
  {
    allowed_units:        Grafito.allowed_units,
    ai_provider:          Grafito.ai_provider,
    timezone:             Grafito.timezone,
    base_path:            Grafito.base_path,
    user_mode:            Grafito.user_mode?,
    auth_configured:      Grafito.auth_configured_override,
    dashboard_enabled:    Grafito.dashboard_enabled?,
    compose_enabled:      Grafito.compose_enabled?,
    apps_enabled:         Grafito.apps_enabled?,
    appstores_spec:       Grafito.appstores_spec,
    appstores_boot_spec:  Grafito.appstores_boot_spec,
    stacks_dir:           Grafito.stacks_dir,
    processes_enabled:    Grafito.processes_enabled?,
    homepage_enabled:     Grafito.homepage_enabled?,
    homepage_config_path: Grafito.homepage_config_path,
    settings_enabled:     Grafito.settings_enabled?,
    data_dir:             Grafito.data_dir,
    lego_bin:             Grafito.lego_bin,
    enable_actions:       Grafito.enable_actions?,
  }
end

def restore_grafito_state(previous) : Nil
  Grafito.allowed_units = previous[:allowed_units]
  Grafito.ai_provider = previous[:ai_provider]
  Grafito.timezone = previous[:timezone]
  Grafito.base_path = previous[:base_path]
  Grafito.user_mode = previous[:user_mode]
  Grafito.auth_configured_override = previous[:auth_configured]
  Grafito.dashboard_enabled = previous[:dashboard_enabled]
  Grafito.compose_enabled = previous[:compose_enabled]
  Grafito.apps_enabled = previous[:apps_enabled]
  Grafito.appstores_spec = previous[:appstores_spec]
  Grafito.appstores_boot_spec = previous[:appstores_boot_spec]
  Grafito.stacks_dir = previous[:stacks_dir]
  Grafito.processes_enabled = previous[:processes_enabled]
  Grafito.homepage_enabled = previous[:homepage_enabled]
  Grafito.homepage_config_path = previous[:homepage_config_path]
  Grafito.settings_enabled = previous[:settings_enabled]
  Grafito.data_dir = previous[:data_dir]
  Grafito.lego_bin = previous[:lego_bin]
  Grafito.enable_actions = previous[:enable_actions]
end

# Holds the snapshot between the global before/after hooks.
class SpecStatePocket
  class_property state : Hash(String, String)?

  alias Snapshot = NamedTuple(
    allowed_units: Array(String)?,
    ai_provider: Grafito::AI::Provider?,
    timezone: String, base_path: String, user_mode: Bool,
    auth_configured: Bool?,
    dashboard_enabled: Bool, compose_enabled: Bool, apps_enabled: Bool,
    appstores_spec: String, appstores_boot_spec: String,
    stacks_dir: String?,
    processes_enabled: Bool, homepage_enabled: Bool,
    homepage_config_path: String, settings_enabled: Bool,
    data_dir: String, lego_bin: String, enable_actions: Bool)

  class_property grafito : Snapshot?
end

Spec.before_each do
  SpecStatePocket.state = ENV.to_h
  SpecStatePocket.grafito = snapshot_grafito_state
end

Spec.after_each do
  if grafito_state = SpecStatePocket.grafito
    restore_grafito_state(grafito_state)
  end
  if env_state = SpecStatePocket.state
    ENV.clear
    env_state.each { |key, value| ENV[key] = value }
  end
end

def dispatch_request(method : String, path : String, body : String? = nil, headers : HTTP::Headers = HTTP::Headers.new)
  io = IO::Memory.new(body.to_s)
  request = HTTP::Request.new(method, path, headers, io)
  response_io = IO::Memory.new
  response = HTTP::Server::Response.new(response_io)
  context = HTTP::Server::Context.new(request, response)

  Kemal::RouteHandler::INSTANCE.call(context)
  response.close

  # Depending on how the route writes its response, the raw IO may
  # contain the full HTTP head. Strip it so specs see just the body;
  # keep the headers either way (e.g. for content-type assertions).
  raw_body = response_io.to_s
  body_text, response_headers = if raw_body.starts_with?("HTTP/")
                                  head, _, rest = raw_body.partition("\r\n\r\n")
                                  parsed = HTTP::Headers.new
                                  head.each_line.skip(1).each do |line|
                                    name, _, value = line.partition(":")
                                    parsed.add(name.strip, value.strip)
                                  end
                                  {rest || "", parsed}
                                else
                                  {raw_body, response.headers}
                                end

  {status: response.status_code, body: body_text, headers: response_headers}
end

# A terminal handler that records whether a request reached it —
# used by handler specs (auth, login) to test middleware directly
# instead of through routes.
class PassMarker
  include HTTP::Handler

  property? passed = false

  def call(context : HTTP::Server::Context) : Nil
    @passed = true
    context.response.status_code = 200
  end
end

# Shared tunnel fixtures: used by both tunnel_settings_spec.cr and
# tunnel_panel_spec.cr, so they live here (per-file helpers must not
# be referenced from other spec files — a single-file `crystal spec`
# run would not see them).

def tunnel_settings : TunnelSettings::Settings
  TunnelSettings::Settings.new(
    enabled: true,
    tunnel_id: "f0f0f0f0-1111-2222-3333-444444444444",
    tunnel_name: "grafito",
    credentials: %q({"AccountTag":"acct","TunnelSecret":"sekrit"}),
  )
end

# Renders one installed app record on disk (app.json), the way the
# app store writes it, so route derivation has something to read.
# (Named differently from access_panel_spec's helper: top-level
# names must not collide across spec files.)
def with_tunnel_installed_app(root : String, store : String, id : String, name : String, port : Int32, domain : String = "", &)
  dir = File.join(root, "apps", store, id)
  Dir.mkdir_p(dir)
  record = AppStore::InstalledApp.new(
    store: store, id: id, name: name, version: "1.0",
    tipi_version: 1, port: port, project_name: id,
    installed_at: Time.utc.to_rfc3339, domain: domain,
  )
  File.write(File.join(dir, "app.json"), record.to_pretty_json)
  yield record
  FileUtils.rm_rf(dir)
end

# Minimal AI provider used to enable AI-dependent UI in specs.
class FakeAIProvider < Grafito::AI::Provider
  def name : String
    "fake"
  end

  def complete(request : Grafito::AI::Request) : Grafito::AI::Response
    Grafito::AI::Response.new(content: "fake explanation", model: "fake-model", provider: "fake")
  end

  def available? : Bool
    true
  end

  def models : Array(Grafito::AI::ModelInfo)
    [] of Grafito::AI::ModelInfo
  end

  def current_model : String
    "fake-model"
  end
end
