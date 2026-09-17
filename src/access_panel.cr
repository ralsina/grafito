# # Access panel
#
# The UI half of the access layer (#138): proxy settings (base
# domain, DNS provider + credentials, lego path), the wildcard
# certificate status, and obtain/renew as a streaming job.
#
# Everything here requires actions + authentication: the settings
# hold a DNS provider API token. And the standing promise holds —
# host:port access to the apps exists with or without any of this.

require "html_builder"
require "json"
require "log"

require "./access"
require "./proxy_settings"

module AccessPanel
  Log = ::Log.for(self)

  extend self

  # Mirrors the other views' base-path handling.
  private def self.route_path(path : String) : String
    Grafito.route_path(path)
  end

  def self.register_routes
    # ## The access panel: settings, certificate status, renew.
    get route_path("access") do |env|
      unless access_allowed?
        env.response.status_code = 403
        next access_rejected_message
      end
      env.response.content_type = "text/html"
      settings = ProxySettings.load(Grafito.data_dir) || ProxySettings::Settings.new(
        enabled: false, base_domain: "", email: "",
        dns_provider: "cloudflare",
        credentials: {} of String => String,
        lego_path: Grafito.lego_bin,
      )
      panel_fragment(settings, saved: false)
    end

    # Saves the settings. The token field is only applied when
    # non-empty, so re-saving other fields doesn't require re-typing
    # the credential.
    post route_path("access/settings") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless access_allowed?
        env.response.status_code = 403
        next access_rejected_message
      end

      settings = ProxySettings.load(Grafito.data_dir) || ProxySettings::Settings.new
      settings.enabled = body_param(env, "enabled") == "true"
      settings.base_domain = (body_param(env, "base_domain") || "").strip
      settings.email = (body_param(env, "email") || "").strip
      provider = (body_param(env, "dns_provider") || "cloudflare").strip
      settings.dns_provider = ProxySettings::DNS_PROVIDERS.includes?(provider) || provider == "custom" ? provider : "cloudflare"
      token = (body_param(env, "token") || "").strip
      unless token.empty?
        env_name = ProxySettings.credential_env(settings.dns_provider)
        settings.credentials = {env_name => token} of String => String
      end
      settings.lego_path = (body_param(env, "lego_path") || settings.lego_path).strip

      ProxySettings.save(Grafito.data_dir, settings)
      Log.info { "Proxy settings saved (base domain: #{settings.base_domain})" }

      env.response.content_type = "text/html"
      panel_fragment(settings, saved: true)
    end

    # ## The managed caddy proxy stack
    #
    # grafito renders its compose file + Caddyfile from the routed
    # apps and starts/stops it as a streaming job. Stopped or broken
    # caddy only costs the domain forms: host:port keeps working.

    post route_path("proxy/start") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless access_allowed?
        env.response.status_code = 403
        next access_rejected_message
      end
      settings = ProxySettings.load(Grafito.data_dir)
      if settings.nil? || settings.base_domain.empty?
        env.response.status_code = 400
        next "Save the proxy settings (base domain) first."
      end

      sync_proxy_files(Grafito.data_dir, settings)
      routes = routes_for_base(settings)
      job_id = ComposeJobs.start_custom("start reverse proxy (#{routes.size} routes)") do |job|
        job.append("Starting caddy on ports 80/443 with #{routes.size} routed domains …")
        compose_file = File.join(proxy_dir(Grafito.data_dir), "docker-compose.yml")
        code = ComposeJobs.run_command(job, ["docker", "compose", "--project-name", "grafito-proxy",
                                             "-f", compose_file, "up", "-d"])
        job.finish(code)
        nil
      end
      env.response.content_type = "text/html"
      job_fragment(job_id, "proxy-status")
    end

    post route_path("proxy/stop") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless access_allowed?
        env.response.status_code = 403
        next access_rejected_message
      end
      settings = ProxySettings.load(Grafito.data_dir)
      if settings.nil? || settings.base_domain.empty?
        env.response.status_code = 400
        next "Save the proxy settings (base domain) first."
      end

      job_id = ComposeJobs.start_custom("stop reverse proxy") do |job|
        job.append("Stopping caddy … apps remain reachable on host:port.")
        compose_file = File.join(proxy_dir(Grafito.data_dir), "docker-compose.yml")
        code = ComposeJobs.run_command(job, ["docker", "compose", "--project-name", "grafito-proxy",
                                             "-f", compose_file, "down"])
        job.finish(code)
        nil
      end
      env.response.content_type = "text/html"
      job_fragment(job_id, "proxy-status")
    end

    # Obtain (first time) or renew the wildcard certificate as a
    # streaming job.
    post route_path("access/cert/renew") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless access_allowed?
        env.response.status_code = 403
        next access_rejected_message
      end
      settings = ProxySettings.load(Grafito.data_dir)
      if settings.nil? || settings.base_domain.empty?
        env.response.status_code = 400
        next "Save the proxy settings first."
      end

      job_id : String
      {% if flag?(:demo_mode) %}
        Log.info { "Demo mode: certificate renewal of *.#{settings.base_domain} simulated" }
        job_id = ComposeJobs.start("renew certificate", [[] of String])
      {% else %}
        job_id = ComposeJobs.start_custom("renew certificate for #{settings.base_domain}") do |job|
          action = File.file?(ProxySettings.cert_path(Grafito.data_dir, settings.base_domain)) ? "renew" : "run"
          job.append("Running lego #{action} for #{settings.base_domain} (DNS-01, provider #{settings.dns_provider}) …")
          result = ProxySettings.run_lego(settings, Grafito.data_dir, action)
          result[:output].each_line { |line| job.append(line) }
          job.finish(result[:success] ? 0 : 1)
          nil
        end
      {% end %}
      env.response.content_type = "text/html"
      job_fragment(job_id, "access-cert-renew")
    end
  end

  # ## Route helpers

  # Same streaming-job fragment the app store uses.
  private def self.job_fragment(job_id : String, anchor : String) : String
    job = ComposeJobs.find(job_id)
    unless job
      return ComposeDashboard.action_error_fragment("Access", "job", "Failed to start the job.")
    end
    ComposeDashboard.output_fragment(job, anchor)
  end

  private def self.appstore_enabled? : Bool
    Grafito.compose_enabled? && Grafito.apps_enabled?
  end

  # The gate: the settings hold a DNS provider API token, so the same
  # actions + authentication bar as the other state-changing endpoints
  # applies.
  private def self.access_allowed? : Bool
    Grafito.compose_enabled? && Grafito.actions_available?
  end

  private def self.access_rejected_message : String
    "Access settings require actions: start grafito with --enable-actions and authentication configured (GRAFITO_AUTH_USER/GRAFITO_AUTH_PASS)."
  end

  private def self.body_param(env : HTTP::Server::Context, key : String) : String?
    env.params.body[key]? || Grafito.optional_query_param(env, key)
  end

  private def self.base : String
    Grafito.base_path == "/" ? "" : Grafito.base_path
  end

  # ## Fragments

  # One routed app: domain → local port.
  record ProxyRoute, domain : String, app_name : String, port : Int32

  # Routed apps: installed apps the user gave a domain, sorted by it.
  # Apps without a domain are not routed — they stay on host:port.
  def self.routes(root : String) : Array(ProxyRoute)
    AppStore.installed(root).compact_map do |installed|
      next if installed.domain.empty?
      ProxyRoute.new(domain: installed.domain, app_name: installed.name, port: installed.port)
    end.sort_by!(&.domain)
  end

  # The managed proxy's files live under <data-dir>/proxy.
  def self.proxy_dir(data_dir : String) : String
    File.join(data_dir, "proxy")
  end

  # The Caddyfile: one site block per routed app, TLS terminating on
  # the wildcard certificate files lego maintains. Apps whose domain
  # is not under the proxy's base domain are skipped (the wildcard
  # does not cover them).
  def self.render_caddyfile(
    routes : Array(ProxyRoute),
    base_domain : String,
    data_dir : String,
  ) : String
    crt = ProxySettings.cert_path(data_dir, base_domain)
    key = ProxySettings.key_path(data_dir, base_domain)
    String.build do |io|
      routes.each do |route|
        next unless route.domain.ends_with?(".#{base_domain}")
        io << "#{route.domain} {\n"
        io << "  tls #{crt} #{key}\n"
        io << "  reverse_proxy 127.0.0.1:#{route.port}\n"
        io << "}\n"
      end
    end
  end

  # The managed caddy stack: host network (upstreams are
  # 127.0.0.1:APP_PORT of the published ports), certificates and
  # Caddyfile mounted read-only.
  def self.render_proxy_compose(data_dir : String) : String
    <<-YAML
      services:
        grafito-proxy:
          image: caddy:2
          container_name: grafito-proxy
          restart: unless-stopped
          network_mode: host
          volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile:ro
            - ../lego:/certs:ro
      YAML
  end

  # Writes the proxy files (Caddyfile + docker-compose.yml) from the
  # current routed apps. Returns the routes actually routed under the
  # proxy's base domain.
  def self.write_proxy_files(data_dir : String, settings : ProxySettings::Settings) : Array(ProxyRoute)
    routes = routes(data_dir).select do |route|
      route.domain.ends_with?(".#{settings.base_domain}")
    end
    dir = proxy_dir(data_dir)
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "Caddyfile"), render_caddyfile(routes, settings.base_domain, data_dir))
    File.write(File.join(dir, "docker-compose.yml"), render_proxy_compose(data_dir))
    routes
  end

  # Writes the proxy files only when their content changed. Returns
  # true when something was rewritten.
  def self.sync_proxy_files(data_dir : String, settings : ProxySettings::Settings) : Bool
    routes = routes(data_dir).select do |route|
      route.domain.ends_with?(".#{settings.base_domain}")
    end
    dir = proxy_dir(data_dir)
    Dir.mkdir_p(dir)

    caddyfile_path = File.join(dir, "Caddyfile")
    compose_path = File.join(dir, "docker-compose.yml")
    files = {
      {caddyfile_path, render_caddyfile(routes, settings.base_domain, data_dir)},
      {compose_path, render_proxy_compose(data_dir)},
    }
    changed = false
    files.each do |path, content|
      if !File.exists?(path) || File.read(path) != content
        File.write(path, content)
        changed = true
      end
    end
    changed
  end

  # True when the managed proxy container is running.
  def self.proxy_running? : Bool
    stdout = IO::Memory.new
    result = Process.run("docker", args: ["ps", "--filter", "name=grafito-proxy", "--format", "{{.Names}}"],
      output: stdout, error: Process::Redirect::Close)
    return false unless result.success?
    stdout.to_s.includes?("grafito-proxy")
  rescue ex
    Log.warn(exception: ex) { "Could not check proxy container state" }
    false
  end

  # Reloads the running proxy without dropping connections (caddy
  # re-reads its config in-place). Best-effort: if it fails, the
  # caller's restart path still applies.
  def self.reload_proxy : Bool
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    result = Process.run("docker", args: ["exec", "grafito-proxy",
                                          "caddy", "reload", "--config", "/etc/caddy/Caddyfile"],
      output: stdout, error: stderr)
    unless result.success?
      Log.warn { "caddy reload failed: #{stderr.to_s.strip}" }
    end
    result.success?
  end

  # The settings + certificate panel. `saved` adds a confirmation
  # banner.
  def self.panel_fragment(settings : ProxySettings::Settings, saved : Bool = false) : String
    HTML.build do
      div(class: "service-panel appstore-panel") do
        tag("h4") { text "Access & domains" }
        if saved
          div(class: "inline-alert") do
            text "Settings saved."
          end
        end

        tag("p") do
          text "Apps are always reachable on "
          span(class: "stat-value") { text "http://host:port" }
          text " — that never changes. This section adds the option to "
          span(class: "stat-value") { text "route apps by domain" }
          text " with automatic HTTPS: you own a domain, create one wildcard DNS record, and one wildcard certificate covers every app."
        end

        html settings_form(settings)
        html certificate_section(settings)
        html proxy_section(settings)
      end
    end
  end

  # Routed apps under the proxy's base domain.
  private def self.routes_for_base(settings : ProxySettings::Settings) : Array(ProxyRoute)
    return [] of ProxyRoute if settings.base_domain.empty?
    routes(Grafito.data_dir).select do |route|
      route.domain.ends_with?(".#{settings.base_domain}")
    end
  end

  # The managed caddy stack: status, start/stop and the route table
  # (domain → app). Stopped or broken caddy degrades to host:port
  # access for every app — the panel says so.
  private def self.proxy_section(settings : ProxySettings::Settings) : String
    running = proxy_running?
    routes = routes_for_base(settings)
    HTML.build do
      div(id: "proxy-section", class: "appstore-backups") do
        span(class: "stat-label") { text "Reverse proxy — managed caddy" }
        span(class: running ? "tag tag-ok" : "tag tag-muted") do
          text running ? "running" : "stopped"
        end
        if routes.empty?
          span(class: "service-panel-hint") do
            text "No routed apps yet: set a domain on an installed app (install form) and it appears here."
          end
        else
          routes.each do |route|
            div(class: "compose-update-row") do
              span(class: "compose-update-service") { text route.domain }
              span(class: "tag tag-info") { text route.app_name }
              span(class: "tag tag-muted") { text "127.0.0.1:#{route.port}" }
            end
          end
        end
        div(class: "service-panel-actions") do
          unless settings.base_domain.empty?
            if running
              button(
                class: "round-button",
                title: "Stop the managed caddy. Apps remain reachable on host:port.",
                "hx-post": "#{base}/proxy/stop",
                "hx-target": "#proxy-section",
                "hx-swap": "innerHTML",
                "hx-confirm": "Stop the reverse proxy? Apps remain reachable on host:port.",
              ) do
                text "stop proxy"
              end
            else
              button(
                class: "round-button",
                title: "Start the managed caddy and route the domains above",
                "hx-post": "#{base}/proxy/start",
                "hx-target": "#proxy-section",
                "hx-swap": "innerHTML",
                "hx-indicator": "#loading-spinner",
              ) do
                text "start proxy"
              end
            end
          end
        end
      end
    end
  end

  # The settings form: base domain, LE email, DNS provider + token,
  # lego path, enable toggle.
  private def self.settings_form(settings : ProxySettings::Settings) : String
    HTML.build do
      tag("form", {"class" => "appstore-install-form", "onsubmit" => "return false"}) do
        div(class: "appstore-field") do
          label(for: "proxy-base-domain") { text "Base domain (apps become app.base_domain)" }
          input(type: "text", id: "proxy-base-domain", name: "base_domain",
            value: settings.base_domain, placeholder: "home.example.com")
        end
        div(class: "appstore-field") do
          label(for: "proxy-email") { text "Let's Encrypt email" }
          input(type: "email", id: "proxy-email", name: "email", value: settings.email)
        end
        div(class: "appstore-field") do
          label(for: "proxy-provider") { text "DNS provider (for the DNS-01 challenge)" }
          tag("select", {"id" => "proxy-provider", "name" => "dns_provider"}) do
            ProxySettings::DNS_PROVIDERS.each do |provider|
              selected = provider == settings.dns_provider ? " selected=\"selected\"" : ""
              html %(<option value="#{provider}"#{selected}>#{provider}</option>)
            end
            selected = settings.dns_provider == "custom" ? " selected=\"selected\"" : ""
            html %(<option value="custom"#{selected}>custom (credentials pre-set)</option>)
          end
        end
        div(class: "appstore-field") do
          label(for: "proxy-token") { text "DNS provider API token" }
          input(type: "password", id: "proxy-token", name: "token",
            placeholder: settings.credentials.empty? ? "" : "(saved — leave blank to keep)")
        end
        div(class: "appstore-field") do
          label(for: "proxy-lego") { text "lego binary path" }
          input(type: "text", id: "proxy-lego", name: "lego_path", value: settings.lego_path)
        end
        div(class: "appstore-field") do
          label(for: "proxy-enabled") { text "Enabled" }
          if settings.enabled?
            input(type: "checkbox", id: "proxy-enabled", name: "enabled", value: "true", checked: "checked")
          else
            input(type: "checkbox", id: "proxy-enabled", name: "enabled", value: "true")
          end
        end

        button(
          class: "service-panel-explain appstore-install-button",
          type: "button",
          "hx-post": "#{base}/access/settings",
          "hx-include": "closest form",
          "hx-target": "#panel-detail-content",
          "hx-swap": "innerHTML",
          "hx-indicator": "#loading-spinner",
        ) do
          text "Save settings"
        end
      end
    end
  end

  # The wildcard-certificate section: status plus the obtain/renew
  # button (streamed through a job), and a port-conflict warning —
  # the proxy needs 80/443, which may be taken or privileged.
  private def self.certificate_section(settings : ProxySettings::Settings) : String
    cert_file = ProxySettings.cert_path(Grafito.data_dir, settings.base_domain)
    cert_exists = File.file?(cert_file) && !settings.base_domain.empty?
    cert_expiry = cert_exists ? ProxySettings.cert_expiry(cert_file) : nil
    conflicts = settings.enabled? ? port_conflicts : [] of Int32

    HTML.build do
      div(class: "appstore-backups") do
        span(class: "stat-label") { text "Wildcard certificate" }
        if settings.base_domain.empty?
          span(class: "service-panel-hint") { text "Set the base domain first." }
        elsif cert_exists && cert_expiry
          span(class: "tag tag-ok") do
            text "valid until #{cert_expiry.to_s("%Y-%m-%d")}"
          end
        else
          span(class: "tag tag-warn") { text "not issued yet" }
        end
        unless settings.base_domain.empty?
          button(
            class: "service-panel-explain",
            "hx-post": "#{base}/access/cert/renew",
            "hx-target": "#access-cert-renew",
            "hx-swap": "innerHTML",
            "hx-indicator": "#loading-spinner",
          ) do
            text cert_exists ? "Renew now" : "Obtain certificate"
          end
          div(id: "access-cert-renew") { }
        end
        unless conflicts.empty?
          span(class: "tag tag-warn") do
            text "port #{conflicts.join(", ")} unavailable (in use, or binding requires privileges) — free it before routing domains"
          end
        end
      end
    end
  end

  # Ports the caddy stack will need; listed when something already
  # listens on them, since the proxy could not bind.
  private def self.port_conflicts : Array(Int32)
    [80, 443].select do |port|
      server = TCPServer.new("0.0.0.0", port)
      server.close
      false
    rescue
      true
    end
  end
end
