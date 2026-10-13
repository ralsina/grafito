# # Tunnel panel
#
# The Cloudflare Tunnel half of the access layer's UI: tunnel
# settings (tunnel ID + credentials pasted from the Cloudflare
# dashboard), the managed cloudflared stack's start/stop, and the
# ingress table (the same routed apps the caddy path serves).
#
# Same bar as the rest of the access panel: everything here requires
# actions + authentication, because the settings hold the tunnel
# credentials secret. And the standing promise holds — host:port
# access to the apps exists with or without any of this.

require "html_builder"
require "json"
require "log"

require "./tunnel_settings"

module TunnelPanel
  Log = ::Log.for(self)

  extend self

  # Mirrors the other views' base-path handling.
  private def self.route_path(path : String) : String
    Grafito.route_path(path)
  end

  def self.register_routes
    # Saves the tunnel settings. The credentials field is only
    # applied when non-empty, so re-saving other fields doesn't
    # require re-pasting the secret.
    post route_path("tunnel/settings") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless access_allowed?
        env.response.status_code = 403
        next access_rejected_message
      end
      save_settings(env)
    end

    # Starts the managed cloudflared stack: dial out to Cloudflare's
    # edge and serve the routed apps' domains. No ports are opened.
    post route_path("tunnel/start") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless access_allowed?
        env.response.status_code = 403
        next access_rejected_message
      end
      start_tunnel(env)
    end

    # Stops the managed cloudflared stack. Stopped tunnel only costs
    # the domain form: host:port keeps working.
    post route_path("tunnel/stop") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless access_allowed?
        env.response.status_code = 403
        next access_rejected_message
      end
      stop_tunnel(env)
    end
  end

  # ## Route handlers
  #
  # (The gates stay in the route blocks — `halt` expands to a `next`,
  # which only means "leave the route" from inside the block itself.)

  # Saves the settings form. A blank credentials field keeps the
  # saved secret; the re-rendered section confirms with a banner.
  private def self.save_settings(env : HTTP::Server::Context) : String
    settings = TunnelSettings.load(Grafito.data_dir) || TunnelSettings::Settings.new
    settings.enabled = body_param(env, "enabled") == "true"
    settings.tunnel_id = (body_param(env, "tunnel_id") || "").strip
    settings.tunnel_name = (body_param(env, "tunnel_name") || "").strip
    credentials = (body_param(env, "credentials") || "").strip
    settings.credentials = credentials unless credentials.empty?

    TunnelSettings.save(Grafito.data_dir, settings)
    Log.info { "Tunnel settings saved (tunnel: #{settings.tunnel_id.empty? ? "not set" : settings.tunnel_id})" }

    env.response.content_type = "text/html"
    tunnel_section(settings, proxy_base_domain, saved: true)
  end

  # Syncs the generated files and starts the stack as a streaming job.
  private def self.start_tunnel(env : HTTP::Server::Context) : String
    settings = TunnelSettings.load(Grafito.data_dir) || TunnelSettings::Settings.new
    unless settings.configured?
      env.response.status_code = 400
      return "Save the tunnel settings (tunnel ID and credentials) first."
    end

    TunnelSettings.sync_tunnel_files(Grafito.data_dir, settings)
    routes = AccessPanel.routes(Grafito.data_dir)
    job_id = ComposeJobs.start_custom("start cloudflare tunnel (#{routes.size} routes)") do |job|
      job.append("Starting cloudflared with #{routes.size} ingress rules — outbound only, no ports opened …")
      compose_file = File.join(TunnelSettings.tunnel_dir(Grafito.data_dir), "docker-compose.yml")
      code = ComposeJobs.run_command(job, ["docker", "compose", "--project-name", "grafito-tunnel",
                                           "-f", compose_file, "up", "-d"])
      job.finish(code)
      nil
    end
    env.response.content_type = "text/html"
    job_fragment(job_id)
  end

  # Stops the stack as a streaming job.
  private def self.stop_tunnel(env : HTTP::Server::Context) : String
    settings = TunnelSettings.load(Grafito.data_dir) || TunnelSettings::Settings.new
    unless settings.configured?
      env.response.status_code = 400
      return "Save the tunnel settings (tunnel ID and credentials) first."
    end

    job_id = ComposeJobs.start_custom("stop cloudflare tunnel") do |job|
      job.append("Stopping cloudflared … apps remain reachable on host:port.")
      compose_file = File.join(TunnelSettings.tunnel_dir(Grafito.data_dir), "docker-compose.yml")
      code = ComposeJobs.run_command(job, ["docker", "compose", "--project-name", "grafito-tunnel",
                                           "-f", compose_file, "down"])
      job.finish(code)
      nil
    end
    env.response.content_type = "text/html"
    job_fragment(job_id)
  end

  # ## Route helpers

  # Same streaming-job fragment the app store and the access panel use.
  private def self.job_fragment(job_id : String) : String
    job = ComposeJobs.find(job_id)
    unless job
      return ComposeDashboard.action_error_fragment("Tunnel", "job", "Failed to start the job.")
    end
    ComposeDashboard.output_fragment(job, "tunnel-status")
  end

  # The gate: the settings hold the tunnel credentials secret, so the
  # same actions + authentication bar as the other state-changing
  # endpoints applies.
  private def self.access_allowed? : Bool
    Grafito.compose_enabled? && Grafito.actions_available?
  end

  private def self.access_rejected_message : String
    "Tunnel settings require actions: start grafito with --enable-actions and authentication configured (GRAFITO_AUTH_USER/GRAFITO_AUTH_PASS)."
  end

  private def self.body_param(env : HTTP::Server::Context, key : String) : String?
    env.params.body[key]? || Grafito.optional_query_param(env, key)
  end

  private def self.base : String
    ViewHelpers.base_prefix
  end

  # The proxy settings' base domain, for the DNS hints. Empty when the
  # caddy path isn't configured — the tunnel works without it.
  private def self.proxy_base_domain : String
    proxy_settings = ProxySettings.load(Grafito.data_dir)
    proxy_settings.try(&.base_domain) || ""
  end

  # ## Fragments

  # The "Cloudflare Tunnel" section of the access panel: settings
  # form, cloudflared status, start/stop and the ingress table (the
  # same routed apps the caddy section shows).
  def self.tunnel_section(settings : TunnelSettings::Settings, base_domain : String, saved : Bool = false) : String
    running = TunnelSettings.tunnel_running?
    routes = AccessPanel.routes(Grafito.data_dir)
    configured = settings.configured?
    HTML.build do
      div(id: "tunnel-section", class: "appstore-backups") do
        span(class: "stat-label") { text "Cloudflare Tunnel — managed cloudflared" }
        span(class: running ? "tag tag-ok" : "tag tag-muted") do
          text running ? "running" : "stopped"
        end
        if saved
          div(class: "inline-alert") do
            text "Tunnel settings saved."
          end
        end

        tag("p") do
          text "The second way to route domains: a "
          tag("code") { text "cloudflared" }
          text " connector dials out to Cloudflare, so no ports face the internet and no public IP is needed — Cloudflare terminates TLS and forwards to the same local ports. The caddy proxy above serves domains whose DNS points at this server; the tunnel serves the ones pointed at Cloudflare. Both can run at once; each hostname goes wherever its DNS record points."
        end

        html tunnel_settings_form(settings)
        if configured
          html tunnel_routes_fragment(routes, base_domain, settings.tunnel_id)
          div(class: "service-panel-actions") do
            if running
              button(
                class: "round-button",
                title: "Stop the managed cloudflared. Apps remain reachable on host:port.",
                "hx-post": "#{base}/tunnel/stop",
                "hx-target": "#tunnel-status",
                "hx-swap": "innerHTML",
                "hx-confirm": "Stop the cloudflare tunnel? Apps remain reachable on host:port.",
              ) do
                text "stop tunnel"
              end
            else
              button(
                class: "round-button",
                title: "Start the managed cloudflared and route the domains above",
                "hx-post": "#{base}/tunnel/start",
                "hx-target": "#tunnel-status",
                "hx-swap": "innerHTML",
                "hx-indicator": "#loading-spinner",
              ) do
                text "start tunnel"
              end
            end
          end
          div(id: "tunnel-status") { }
        else
          span(class: "service-panel-hint") do
            text "Paste the tunnel ID and credentials (Cloudflare dashboard → Zero Trust → Networks → Tunnels → your tunnel) to get started."
          end
        end
        html tunnel_explain_fragment
      end
    end
  end

  # The settings form: tunnel ID, name, credentials JSON, enable
  # toggle. Saved in <data-dir>/tunnel-settings.json (0600).
  private def self.tunnel_settings_form(settings : TunnelSettings::Settings) : String
    HTML.build do
      tag("form", {"class" => "appstore-install-form", "onsubmit" => "return false"}) do
        div(class: "appstore-field") do
          label(for: "tunnel-id") { text "Tunnel ID" }
          input(type: "text", id: "tunnel-id", name: "tunnel_id",
            value: settings.tunnel_id, placeholder: "the tunnel's UUID, from its dashboard page")
        end
        div(class: "appstore-field") do
          label(for: "tunnel-name") { text "Tunnel name (optional, display only)" }
          input(type: "text", id: "tunnel-name", name: "tunnel_name", value: settings.tunnel_name)
        end
        div(class: "appstore-field") do
          label(for: "tunnel-credentials") { text "Tunnel credentials (the tunnel's JSON)" }
          tag("textarea", {"id" => "tunnel-credentials", "name" => "credentials", "rows" => "3",
                           "autocomplete" => "off",
                           "placeholder" => settings.credentials.empty? ? %q({"AccountTag":"…","TunnelSecret":"…"}) : "(saved — leave blank to keep)"}) { text "" }
        end
        div(class: "appstore-field") do
          label(for: "tunnel-enabled") { text "Enabled" }
          if settings.enabled?
            input(type: "checkbox", id: "tunnel-enabled", name: "enabled", value: "true", checked: "checked")
          else
            input(type: "checkbox", id: "tunnel-enabled", name: "enabled", value: "true")
          end
        end

        button(
          class: "service-panel-explain appstore-install-button",
          type: "button",
          "hx-post": "#{base}/tunnel/settings",
          "hx-include": "closest form",
          "hx-target": "#tunnel-section",
          "hx-swap": "outerHTML",
          "hx-indicator": "#loading-spinner",
        ) do
          text "Save tunnel settings"
        end
      end
    end
  end

  # The ingress table — the same routed apps as the caddy section,
  # every routed domain (the tunnel serves whatever hostname DNS
  # points at it, not only ones under the base domain) — plus the
  # one-time DNS hint.
  private def self.tunnel_routes_fragment(routes : Array(AccessPanel::ProxyRoute), base_domain : String, tunnel_id : String) : String
    HTML.build do
      if routes.empty?
        span(class: "service-panel-hint") do
          text "No routed apps yet: set a domain on an installed app (install form) and it appears here."
        end
      else
        routes.each do |route|
          div(class: "compose-update-row") do
            span(class: "compose-update-service") { text route.domain }
            span(class: "tag tag-info") { text route.app_name }
            span(class: "tag tag-muted") { text "localhost:#{route.port}" }
            unless base_domain.empty? || route.domain.ends_with?(".#{base_domain}")
              span(class: "tag tag-warn") { text "needs its own DNS record" }
            end
          end
        end
      end
      unless base_domain.empty?
        span(class: "service-panel-hint") do
          text "One-time DNS: point the proxied CNAME *.#{base_domain} at #{tunnel_id}.cfargotunnel.com — every app domain under #{base_domain} then flows through the tunnel."
        end
      end
    end
  end

  # The "teach me the commands" block: what the UI manages, in shell
  # commands. `details` keeps it out of the way until asked for.
  private def self.tunnel_explain_fragment : String
    data_dir = Grafito.data_dir
    HTML.build do
      tag("details", class: "proc-explain") do
        tag("summary") do
          span(class: "material-icons", style: "font-size: 1rem; vertical-align: middle;") do
            text "school"
          end
          text " How this works, in shell commands"
        end
        div(class: "proc-explain-body") do
          tag("p") do
            text "The tunnel is one cloudflared connector grafito runs as a compose stack. Its ingress rules — hostname → localhost:port, one per routed app — are generated into "
            tag("code") { text "#{data_dir}/tunnel/config.yml" }
            text " and re-applied whenever apps change. To do the same by hand:"
          end
          tag("pre", class: "explain-commands") do
            text <<-COMMANDS
              # one time, on any machine with the cloudflared CLI:
              cloudflared tunnel login
              cloudflared tunnel create grafito    # prints the tunnel ID + credentials JSON
              cloudflared tunnel route dns -f grafito '*.home.example.com'

              # what the buttons run:
              docker compose --project-name grafito-tunnel -f #{data_dir}/tunnel/docker-compose.yml up -d
              docker compose --project-name grafito-tunnel -f #{data_dir}/tunnel/docker-compose.yml down

              # after app changes rewrite config.yml:
              docker restart grafito-tunnel

              # the connector's own view of the world:
              docker logs grafito-tunnel
              COMMANDS
          end
        end
      end
    end
  end
end
