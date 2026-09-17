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
