# [markdown]
# # Grafito
#
# Welcome to the Grafito source code! I will try to make this code have
# comments in the literate programming style, so when passing it through
# a tool such as [crycco](https://crycco.ralsina.me) it will turn into
# a readable guided tour.
#
# It doesn't hurt that there is not so much code 🤣
#
# Grafito is a simple log viewer. While it tries to have a nice UI, the
# *idea* itself is simple. Your Linux system already provides a nice
# log management system in `journald` but accessing it via the terminal
# using `journalctl` is a bit old fashioned and not terribly convenient.
#
# One solution many use is to use some sort of log collection and viewing
# stack, such as Grafana and others. While those solutions make sense for
# a complex infrastructure in a company, I don´t think a personal server
# or homelab has the same requirements.
#
# Therefore, Grafito tries to expose the important bits of `journald` in
# a comfortable environment. View the logs. Filter them in the most common
# ways. Provide, when possible, escape hatches so you can just drop down
# into the more powerful terminal.
#
# Don´t try to replace the existing, built-in solution that you already
# have working, but build upon it.
#
# ALso, choose the tooling so it's easy to install, requires minimal setup
# and configuration and is performant. Easy, right?

# ## main.cr

require "./grafito"
require "./assets"
require "./ai/config"
require "./gotify/client"
require "./gotify/rules"
require "./metrics_store"
require "baked_file_handler"
require "baked_file_system"
require "docopt-config"
require "kemal-basic-auth"
require "kemal"
require "log"
require "socket"

# This file [main.cr](main.cr.html) is the starting point for grafito. We get the instructions from the
# user about how to start via the command line, using [docopt](https://docopt.org)
# which lets us just write the help and then everything Just Works.
#
# Since one of the goals is easy setup and minimal config, there are exactly 4 configurable things:
#
# * Address
# * Port
# * User
# * Password
#
# And they are all optinal ;-)

DOC = <<-DOCOPT
    Grafito - A simple log viewer.

    Usage:
      grafito [options]
      grafito (-h | --help)
      grafito --version

  Options:
    -p PORT, --port=PORT          Port to listen on [default: 3000].
    -b ADDRESS, --bind=ADDRESS    Address to bind to [default: 127.0.0.1].
    -U UNITS, --units=UNITS       Comma-separated list of systemd units to show in the logs (restricts visibility).
    --log-level=LEVEL             Set log level (debug, info, warn, error, fatal) [default: info].
    -t TIMEZONE, --timezone=TIMEZONE  Timezone for timestamps (e.g., America/New_York, Europe/London, GMT+5, local) [default: local].
    --base-path=PATH              Base path for deployment (e.g., /, /grafito) [default: /].
    --user                       Enable user systemd mode (use journalctl --user and systemctl --user) [default: false].
    --dashboard=BOOL             Enable the server dashboard and metrics sampler (true/false) [default: true].
    --compose=BOOL               Enable the Docker Compose view (true/false) [default: true].
    --apps=BOOL                  Enable the app store in the Compose view (true/false) [default: true].
    --appstores=LIST             App stores as comma-separated name=tarball-url pairs [default: official=https://codeload.github.com/runtipi/runtipi-appstore/tar.gz/refs/heads/master].
    --processes=BOOL             Enable the process monitor view (true/false) [default: true].
    --homepage=BOOL              Enable the homepage view (true/false) [default: true].
    --homepage-config=PATH       Homepage view config file (YAML) [default: /etc/grafito/homepage.yml].
    --data-dir=PATH              Directory for metrics history, app store caches and installed apps [default: /var/lib/grafito].
    --sample-interval-sec=N      Dashboard metrics sampling interval in seconds [default: 30].
    --retention-days=N           Days of dashboard metrics history to keep [default: 7].
    --enable-actions             Allow start/stop/restart/enable/disable of units from the dashboard (requires authentication) [default: false].
    --idle-timeout-sec=TIMEOUT    Idle timeout in seconds after which to shut down. Primarily useful with systemd socket activation.
    -h --help                     Show this screen.
    --version                     Show version.

  Environment variables:
    GRAFITO_AUTH_USER             Username for basic authentication (if set, GRAFITO_AUTH_PASS must also be set).
    GRAFITO_AUTH_PASS             Password for basic authentication (if set, GRAFITO_AUTH_USER must also be set).
    LOG_LEVEL                     Log level (debug, info, warn, error, fatal) [default: info].
    GRAFITO_TIMEZONE              Timezone for timestamps (e.g., America/New_York, Europe/London, GMT+5, local) [default: local].
    GRAFITO_BASE_PATH             Base path for deployment (e.g., /, /grafito) [default: /].
    GRAFITO_USER_MODE            Enable user systemd mode (true/false) [default: false].
    GRAFITO_DASHBOARD            Enable the server dashboard (true/false) [default: true].
    GRAFITO_COMPOSE              Enable the Docker Compose view (true/false) [default: true].
    GRAFITO_APPS                 Enable the app store in the Compose view (true/false) [default: true].
    GRAFITO_APPSTORES            App stores as comma-separated name=tarball-url pairs [default: official=https://codeload.github.com/runtipi/runtipi-appstore/tar.gz/refs/heads/master].
    GRAFITO_PROCESSES            Enable the process monitor view (true/false) [default: true].
    GRAFITO_HOMEPAGE             Enable the homepage view (true/false) [default: true].
    GRAFITO_HOMEPAGE_CONFIG      Homepage view config file (YAML) [default: /etc/grafito/homepage.yml].
    GRAFITO_DATA_DIR             Directory for metrics history, app store caches and installed apps [default: /var/lib/grafito].
    GRAFITO_SAMPLE_INTERVAL_SEC  Dashboard metrics sampling interval in seconds [default: 30].
    GRAFITO_RETENTION_DAYS       Days of dashboard metrics history to keep [default: 7].
    GRAFITO_ENABLE_ACTIONS       Allow unit start/stop/restart from the dashboard (true/false) [default: false].
    GRAFITO_GOTIFY_URL           Base URL of a Gotify server to enable push alerts.
    GRAFITO_GOTIFY_TOKEN         Gotify application token (required with GRAFITO_GOTIFY_URL).
    GRAFITO_GOTIFY_PRIORITY      Gotify message priority [default: 5].
    GRAFITO_ALERT_DISK_PCT       Disk usage alert threshold in percent [default: 90].
    GRAFITO_ALERT_ERRORS_PER_MIN Error-rate alert threshold (errors per minute) [default: 10].
    LISTEN_FDS                    Used for systemd socket activation. If set to 1, binds to the socket passed as fd 3.
  DOCOPT

# This `main()`function is called from the top-level so it's code that
# always gets executed.

def main
  # We parse the command line (`ARGV`) using the help we described above.
  # docopt-config automatically handles environment variables with GRAFITO_ prefix
  # and optional config files.

  args = Docopt.docopt_config(
    DOC,
    argv: ARGV,
    version: Grafito::VERSION,
    env_prefix: "GRAFITO",
    config_file_path: ENV["GRAFITO_CONFIG"]?
  )

  # Set log level from command line argument
  log_level = args["--log-level"].to_s.upcase
  ENV["LOG_LEVEL"] = log_level
  Log.setup_from_env

  # Port and binding address are important
  port = parse_port(args)
  bind_address = args["--bind"].to_s

  # Parse units restriction if provided
  parse_units(args)

  parse_idle_timeout(args)

  # Parse timezone configuration
  # docopt-config handles the fallback automatically: CLI > env var > config > default
  timezone = args["--timezone"].to_s
  Grafito.timezone = timezone
  Grafito::Log.info { "Using timezone: #{timezone}" }

  # Parse base path configuration
  # docopt-config handles the fallback automatically: CLI > env var > config > default
  base_path = args["--base-path"].to_s
  Grafito.base_path = base_path
  Grafito::Log.info { "Using base path: #{base_path}" }

  # Parse user mode configuration
  # docopt-config handles the fallback automatically: CLI > env var > config > default
  user_mode_str = args["--user"].to_s
  Grafito.user_mode = (user_mode_str == "true")
  Grafito::Log.info { "User mode: #{Grafito.user_mode? ? "enabled" : "disabled"}" }

  # Read credentials and configure authentication first: the dashboard
  # setup needs to know whether actions may be enabled.
  auth_user = ENV["GRAFITO_AUTH_USER"]?
  auth_pass = ENV["GRAFITO_AUTH_PASS"]?
  setup_basic_auth(auth_user, auth_pass)

  # Parse dashboard configuration. The dashboard itself, the metrics
  # sampler and (optionally) Gotify alerts all hang off this switch.
  setup_dashboard(args)

  # Parse compose view configuration. The compose endpoints hang off
  # this switch; its action buttons additionally require the same
  # --enable-actions + authentication gate as the dashboard's.
  Grafito.compose_enabled = args["--compose"].to_s != "false"
  Grafito::Log.info { "Compose view: #{Grafito.compose_enabled? ? "enabled" : "disabled"}" }

  # Parse app store configuration.
  parse_app_store_config(args)

  # Parse process view configuration. Its kill actions go through the
  # same --enable-actions + authentication gate as the dashboard's.
  Grafito.processes_enabled = args["--processes"].to_s != "false"
  Grafito::Log.info { "Process view: #{Grafito.processes_enabled? ? "enabled" : "disabled"}" }

  # Privileged actions over plain HTTP on a reachable interface are a
  # bad idea: credentials and commands travel unencrypted. Loopback is
  # fine (TLS is then the reverse proxy's or the user's local concern).
  if Grafito.enable_actions? &&
     !["127.0.0.1", "localhost", "::1"].includes?(args["--bind"].to_s)
    Grafito::Log.warn { "Actions are enabled while bound to #{args["--bind"]}: credentials and commands travel unencrypted. Put grafito behind a TLS reverse proxy for remote access (see README: Securing a Remote Deployment)." }
  end

  # Demo builds always offer actions: every action endpoint simulates
  # its effect against the fake data, so no credentials are needed.
  # Set after the unencrypted-transport warning above, which is about
  # real deployments and would only be noise here.
  {% if flag?(:demo_mode) %}
    Grafito.enable_actions = true
    Grafito::Log.info { "Demo mode: actions enabled, their effects are simulated" }
  {% end %}

  # Parse homepage view configuration. The view itself is harmless
  # without a config file (it renders setup instructions instead), so
  # like the other views it is enabled by default.
  Grafito.homepage_enabled = args["--homepage"].to_s != "false"
  Grafito.homepage_config_path = args["--homepage-config"].to_s
  Grafito::Log.info { "Homepage view: #{Grafito.homepage_enabled? ? "enabled" : "disabled"} (config: #{Grafito.homepage_config_path})" }

  # Register all Kemal routes (must be done after base_path is set)
  Grafito.register_routes

  # Initialize AI provider using the abstraction layer
  setup_ai_provider

  # The `BakedFileHandler` is a custom handler that serves files that are baked
  # into the application. In our case, the Assets class we defined above.
  #
  # Uses the external ralsina/baked_file_handler library. Cache-Control is
  # capped so deployments behind caching proxies don't pin stale frontends;
  # the CacheHeadersHandler further forces no-cache on HTML responses.
  baked_asset_handler = BakedFileHandler::BakedFileHandler.new(
    Assets,
    mount_path: Grafito.base_path,
    cache_control: "public, max-age=300",
  )
  use baked_asset_handler

  # Check if systemd passed a socket file descriptor to start from
  listen_fds = ENV["LISTEN_FDS"]?.to_s.to_i { 0 }
  if listen_fds > 1
    Grafito::Log.fatal { "Unexpectedly got more than 1 socket from systemd" }
    exit 1
  end
  socket_activation = listen_fds == 1

  # Start kemal. That's it. The rest is done in [grafito.cr](grafito.cr.html)
  # where the kemal endpoints are defined.
  # Clear ARGV so Kemal doesn't try to parse command line arguments
  ARGV.clear
  # If systemd socket activation is in use, don't shut down the socket when we exit.
  # Systemd manages the lifetime of the socket in that case.
  Kemal.run(trap_signal: !socket_activation) do |config|
    # The HTTP server is initialized by Kemal before starting this block
    server = config.server
    if server.nil?
      Grafito::Log.fatal { "Kemal did not initialize an HTTP server" }
      exit 1
    end
    if socket_activation
      Grafito::Log.info { "Starting Grafito server via systemd socket activation" }
      # Start kemal listening on the socket passed by socket activation
      server.bind(TCPServer.new(fd: 3))
    else
      Grafito::Log.info { "Starting Grafito server on #{bind_address}:#{port}" }
      # Start kemal listening on the user-specified address and port
      server.bind_tcp(bind_address, port)
    end
  end
end

# Parses app store configuration. The app store rides on the compose
# view (and its actions need the same gate as the other compose
# actions); its caches and installed apps live under --data-dir.
def parse_app_store_config(args)
  Grafito.apps_enabled = args["--apps"].to_s != "false"
  Grafito.appstores_spec = args["--appstores"].to_s
  Grafito.data_dir = Grafito::MetricsStore.resolve_data_dir(args["--data-dir"].to_s)
  Grafito::Log.info { "App store: #{Grafito.apps_enabled? ? "enabled" : "disabled"} (data dir: #{Grafito.data_dir})" }
end

# Returns the port to listen on, parsing the docopt argument which may
# arrive as Int32 (parsed default or config file) or String (command line).
# Exits with a clear message on invalid values.
def parse_port(args) : Int32
  port_value = args["--port"]
  port : Int32? = nil
  case port_value
  when Int32  then port = port_value
  when String then port = port_value.to_i?
  end
  unless port && port > 0 && port <= 65535
    Grafito::Log.fatal { "Invalid port '#{port_value}': must be a number between 1 and 65535." }
    exit 1
  end
  port
end

# Applies the units restriction from the parsed arguments, if any.
def parse_units(args)
  units_arg = args["--units"]?
  if units_arg.is_a?(String) && !units_arg.strip.empty?
    units = units_arg.split(",").map(&.strip)
    Grafito.allowed_units = units
    Grafito::Log.info { "Restricting to units: #{units.join(", ")}" }
  end
end

# Applies the idle shutdown timeout from the parsed arguments, if any.
def parse_idle_timeout(args)
  if args["--idle-timeout-sec"]?
    timeout = args["--idle-timeout-sec"].to_s.to_i32
    if timeout > 0
      Grafito.idle_timeout_sec = timeout
      Grafito::Log.info { "Will shut down after #{timeout}s without any requests" }
    end
  end
end

# Initializes the AI provider from the configured API keys, if any.
# Supports: Anthropic (ANTHROPIC_API_KEY), Z.AI (Z_AI_API_KEY),
# OpenAI (OPENAI_API_KEY), Groq (GROQ_API_KEY), Ollama (GRAFITO_AI_ENDPOINT),
# and ChatJimmy (GRAFITO_AI_PROVIDER=jimmy, never auto-detected).
def setup_ai_provider
  ai_provider = Grafito::AI::Config.provider
  if ai_provider
    Grafito::Log.info { "AI features enabled: #{ai_provider.name}" }
    Grafito.ai_provider = ai_provider
  else
    Grafito::Log.info { "AI features disabled - no provider configured" }
    Grafito::Log.info { "  Set ANTHROPIC_API_KEY or Z_AI_API_KEY to enable" }
    Grafito.ai_provider = nil
  end
end

# Enables basic authentication when both credentials are configured,
# refuses to run half-configured, and warns when running unprotected.
def setup_basic_auth(auth_user : String?, auth_pass : String?)
  if auth_user && auth_pass
    Grafito::Log.info { "Basic Authentication enabled. User: #{auth_user}" }
    basic_auth auth_user, auth_pass
    Grafito.auth_configured = true
  elsif auth_user || auth_pass
    # Only one of the credentials was set - this is a misconfiguration.
    # Exit with an error code to prevent running in an insecure state.
    Grafito::Log.fatal { "Basic Authentication misconfigured: Both GRAFITO_AUTH_USER and GRAFITO_AUTH_PASS must be set if authentication is intended." }
    exit 1
  else
    # Neither username nor password are set, run without authentication.
    Grafito::Log.warn { "Basic Authentication is DISABLED. To enable, set GRAFITO_AUTH_USER and GRAFITO_AUTH_PASS environment variables." }
  end
end

# Applies the dashboard options and starts the metrics sampler (with
# Gotify alert evaluation as the per-sample callback) when enabled.
def setup_dashboard(args) : Nil
  Grafito.dashboard_enabled = args["--dashboard"].to_s != "false"
  Grafito.enable_actions = args["--enable-actions"].to_s == "true"
  Grafito::Log.info { "Dashboard: #{Grafito.dashboard_enabled? ? "enabled" : "disabled"}" }

  if Grafito.enable_actions?
    # State-changing endpoints on an unauthenticated server are a bad
    # idea, full stop: actions require credentials.
    if Grafito.auth_configured?
      Grafito::Log.info { "Unit actions: enabled (permitted by the user grafito runs as and polkit)" }
    else
      Grafito.enable_actions = false
      Grafito::Log.warn { "Unit actions disabled: authentication is not configured (set GRAFITO_AUTH_USER and GRAFITO_AUTH_PASS)" }
    end
  end

  return unless Grafito.dashboard_enabled?

  interval = args["--sample-interval-sec"].to_s.to_i?
  interval = 30 if interval.nil? || interval < 5
  retention = args["--retention-days"].to_s.to_i?
  retention = 7 if retention.nil? || retention < 1
  data_dir = Grafito::MetricsStore.resolve_data_dir(args["--data-dir"].to_s)
  Grafito::Log.info { "Metrics: sampling every #{interval}s into #{data_dir}, keeping #{retention} days" }
  Grafito.metrics_store = Grafito::MetricsStore.start(data_dir, interval, retention) { |snapshot| evaluate_alerts(snapshot) }
end

# Evaluates the Gotify alert rules against a fresh system snapshot and
# sends any debounced alerts. Called from the metrics sampler fiber; a
# failure here must never take sampling down, so everything is guarded.
def evaluate_alerts(snapshot : SystemStatus::Snapshot) : Nil
  return unless Grafito::Gotify::Config.enabled?

  # The error rate needs a journal query; skip the cost when there is
  # no Gotify server configured.
  error_count = Journalctl.query(since: "-1m", priority: "3", lines: 1000)
  errors_per_min = error_count ? error_count.size.to_f : 0.0

  client = Grafito::Gotify::Client.new
  alerts = ALERT_RULES.evaluate(
    disk_used_pct: snapshot.disk_used_pct,
    failed_units: snapshot.units.select(&.failed?).map(&.unit),
    errors_per_min: errors_per_min,
  )
  alerts.each do |alert|
    Grafito::Gotify::Config::Log.info { "Sending alert '#{alert.rule}': #{alert.title}" }
    client.send_notification(alert.title, alert.message)
  end
rescue ex
  Grafito::Gotify::Config::Log.error(exception: ex) { "Alert evaluation failed" }
end

# Long-lived alert rules so the debounce state survives across samples.
ALERT_RULES = Grafito::Gotify::Rules.new

main()
