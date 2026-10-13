# # Tunnel settings
#
# Configuration and file rendering for the access layer's Cloudflare
# Tunnel path: a managed `cloudflared` container dials out to
# Cloudflare's edge, so apps are reachable by domain with **no open
# ports and no public IP** — Cloudflare terminates TLS at the edge and
# forwards to the same `localhost:<port>` upstreams the caddy path
# uses.
#
# Settings live in `<data-dir>/tunnel-settings.json` (0600 — they
# hold the tunnel credentials pasted from the Cloudflare dashboard).
# The generated files live in `<data-dir>/tunnel/` (`config.yml`,
# `docker-compose.yml`, `credentials.json`), mirroring the managed
# caddy stack under `<data-dir>/proxy/`.

require "json"
require "log"

module TunnelSettings
  Log = ::Log.for(self)

  extend self

  class Settings
    include JSON::Serializable

    property? enabled : Bool = false
    property tunnel_id : String = ""
    property tunnel_name : String = ""
    property credentials : String = ""

    def initialize(
      enabled : Bool = false,
      tunnel_id : String = "",
      tunnel_name : String = "",
      credentials : String = "",
    )
      @enabled = enabled
      @tunnel_id = tunnel_id
      @tunnel_name = tunnel_name
      @credentials = credentials
    end

    # Enough to run the connector: cloudflared needs both the tunnel
    # UUID and its credentials secret.
    def configured? : Bool
      !@tunnel_id.empty? && !@credentials.empty?
    end
  end

  # ## Storage

  def self.path(data_dir : String) : String
    File.join(data_dir, "tunnel-settings.json")
  end

  def self.load(data_dir : String) : Settings?
    settings_path = path(data_dir)
    return unless File.file?(settings_path)
    Settings.from_json(File.read(settings_path))
  rescue ex
    Log.error(exception: ex) { "Failed to read #{settings_path}" }
    nil
  end

  # Persists settings with owner-only permissions: the file holds the
  # tunnel credentials secret.
  def self.save(data_dir : String, settings : Settings) : Nil
    settings_path = path(data_dir)
    File.write(settings_path, settings.to_pretty_json, perm: 0o600)
    File.chmod(settings_path, 0o600)
  rescue ex
    Log.error(exception: ex) { "Failed to save #{settings_path}" }
  end

  # ## File rendering

  # The managed tunnel's files live under <data-dir>/tunnel.
  def self.tunnel_dir(data_dir : String) : String
    File.join(data_dir, "tunnel")
  end

  # The cloudflared config: one ingress rule per routed app — every
  # routed domain, not just the ones under the proxy's base domain,
  # because the tunnel serves whatever hostname DNS points at it —
  # ending in the mandatory catch-all rule.
  def self.render_tunnel_config(routes : Array(AccessPanel::ProxyRoute), tunnel_id : String) : String
    String.build do |io|
      io << "tunnel: #{tunnel_id}\n"
      io << "credentials-file: /etc/cloudflared/credentials.json\n"
      io << "ingress:\n"
      routes.each do |route|
        io << "  - hostname: #{route.domain}\n"
        io << "    service: http://localhost:#{route.port}\n"
      end
      io << "  - service: http_status:404\n"
    end
  end

  # The managed cloudflared stack: host network, so `localhost:<port>`
  # upstreams reach the apps' published ports exactly like caddy's do.
  def self.render_tunnel_compose : String
    <<-YAML
      services:
        grafito-tunnel:
          image: cloudflare/cloudflared:latest
          container_name: grafito-tunnel
          restart: unless-stopped
          network_mode: host
          command:
            - tunnel
            - --no-autoupdate
            - --config
            - /etc/cloudflared/config.yml
            - run
          volumes:
            - ./config.yml:/etc/cloudflared/config.yml:ro
            - ./credentials.json:/etc/cloudflared/credentials.json:ro
      YAML
  end

  # Writes the tunnel files (config.yml + docker-compose.yml +
  # credentials.json) from the current routed apps, but only where the
  # content changed. Returns true when something was rewritten.
  def self.sync_tunnel_files(data_dir : String, settings : Settings) : Bool
    routes = AccessPanel.routes(data_dir)
    dir = tunnel_dir(data_dir)
    Dir.mkdir_p(dir)

    config_path = File.join(dir, "config.yml")
    compose_path = File.join(dir, "docker-compose.yml")
    files = {
      {config_path, render_tunnel_config(routes, settings.tunnel_id)},
      {compose_path, render_tunnel_compose},
    }
    changed = false
    files.each do |file_path, content|
      if !File.exists?(file_path) || File.read(file_path) != content
        File.write(file_path, content)
        changed = true
      end
    end

    credentials_path = File.join(dir, "credentials.json")
    unless settings.credentials.empty?
      if !File.exists?(credentials_path) || File.read(credentials_path) != settings.credentials
        File.write(credentials_path, settings.credentials, perm: 0o600)
        File.chmod(credentials_path, 0o600)
        changed = true
      end
    end
    changed
  end

  # ## Runtime state

  # True when the managed tunnel container is running.
  def self.tunnel_running? : Bool
    stdout = IO::Memory.new
    result = Process.run("docker", args: ["ps", "--filter", "name=grafito-tunnel", "--format", "{{.Names}}"],
      output: stdout, error: Process::Redirect::Close)
    return false unless result.success?
    stdout.to_s.includes?("grafito-tunnel")
  rescue ex
    Log.warn(exception: ex) { "Could not check tunnel container state" }
    false
  end

  # Restarts the connector so it picks up the rewritten config.
  # cloudflared reads its ingress at startup, so a restart is the
  # refresh (a ~2s reconnect through the edge).
  def self.restart_tunnel : Bool
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    result = Process.run("docker", args: ["restart", "grafito-tunnel"], output: stdout, error: stderr)
    unless result.success?
      Log.warn { "cloudflared restart failed: #{stderr.to_s.strip}" }
    end
    result.success?
  end

  # Best-effort refresh after install/update/uninstall changes the set
  # of domain-routed apps: rewrite the generated files when their
  # content changed and restart the running connector. No-op when the
  # tunnel is not running (host:port keeps working regardless).
  def self.refresh : Bool
    settings = load(Grafito.data_dir)
    return false if settings.nil? || !settings.configured?
    return false unless tunnel_running?

    changed = sync_tunnel_files(Grafito.data_dir, settings)
    if changed
      restart_tunnel
      Log.info { "Tunnel refresh after app store change: cloudflared restarted" }
    end
    changed
  rescue ex
    Log.warn(exception: ex) { "Tunnel refresh failed (apps remain reachable on host:port)" }
    false
  end
end
