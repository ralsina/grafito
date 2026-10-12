# # Homepage view
#
# A launcher page for self-hosted apps, in the spirit of
# [gethomepage](https://gethomepage.dev) but deliberately smaller: a
# list of service cards grouped by category, an optional weather
# widget (see [weather.cr](weather.cr.html)), and optional up/down
# dots for services that opt into reachability checks.
#
# Like the dashboard and compose views, it is an HTMX fragment: the
# frontend polls `GET /homepage` every 60 seconds and swaps it into
# `#homepage-view`. The list of services comes from a YAML file (see
# [homepage_config.cr](homepage_config.cr.html)); nothing about the
# page is stored in a database.
#
# Weather is fetched per fragment render but cached inside the
# Weather module; reachability checks are cached here for a minute,
# run concurrently, and are strictly opt-in per service.
#
# The config file itself is editable from the page: an Edit button
# (when actions are allowed) opens a YAML editor in the inspector's
# Detail panel, following the compose stack file editor's
# edit → review diff → apply flow. Applying writes the file
# atomically with a rolling backup and retires the settings-store
# overlay, whose values were baked into the editor's starting point.

require "html_builder"
require "http/client"
require "log"
require "mutex"

require "./homepage_config"
require "./view_helpers"
require "./weather"
require "./timeline"
require "./access"

module HomepageDashboard
  extend self

  Log = ::Log.for(self)

  # How long reachability results are reused across fragment renders.
  STATUS_CACHE_TTL = 60.seconds

  # How long a single reachability probe may take. Checked
  # concurrently, so the fragment render is bounded by this, not by
  # the number of services. Generous on purpose: grafito itself
  # blocks its event loop while journalctl runs (it can take well
  # over a second), which would make a tight timeout read as "down".
  CHECK_TIMEOUT = 2.5.seconds

  # @@status_cache slot: fetch time and the last probe results. The
  # value carries the probe latency so dots can show how fast an app
  # answered, not just whether it did.
  @@status_mutex = Mutex.new
  @@status_cache : {Time, Hash(String, ReachResult)}? = nil

  # One reachability probe outcome: up/down and how long the app took
  # to answer (nil when it never answered).
  record ReachResult, up : Bool, latency_ms : Int64?

  # Renders the homepage fragment. Pure: `weather_snapshot` and
  # `statuses` are provided by the caller so specs can render without
  # touching the network.
  def render_html(
    config : HomepageConfig::Config,
    weather_snapshot : Weather::Snapshot? = nil,
    statuses : Hash(String, ReachResult) = {} of String => ReachResult,
    failed_units : Array(String) = [] of String,
    errors_last_hour : Int32 = 0,
    metrics : Grafito::MetricsStore::MetricPoint? = nil,
    installed_apps : Array(AppStore::InstalledApp) = [] of AppStore::InstalledApp,
    hostname : String? = nil,
    edit_url : String? = nil,
  ) : String
    HTML.build do
      div(class: "homepage-top") do
        div(class: "homepage-title") do
          tag("h2") do
            text config.title
          end
          if url = edit_url
            html edit_button_fragment(url)
          end
        end
        if weather_config = config.weather
          html weather_fragment(weather_config, weather_snapshot)
        end
      end

      div(class: "homepage-health") do
        html system_card(failed_units, errors_last_hour)
        html machine_stats_fragment(metrics)
      end

      unless config.groups.empty?
        div(class: "homepage-grid") do
          config.groups.each do |group|
            html group_fragment(group, statuses)
          end
        end
      end

      # Discovery: installed store apps show up automatically, each
      # linking to its access URL (https://domain when routed,
      # http://host:port as the baseline), with live reachability dots.
      unless installed_apps.empty?
        div(class: "homepage-grid") do
          html group_fragment(installed_apps_group(installed_apps, hostname), statuses)
        end
      end
    end
  end

  # Builds the "Installed apps" group from the app store's installed
  # records: one card per app, linking to its access URL (the routed
  # domain when set, host:port as the baseline) and probed like any
  # config-driven service.
  private def self.installed_apps_group(
    installed_apps : Array(AppStore::InstalledApp),
    hostname : String?,
  ) : HomepageConfig::Group
    services = installed_apps.map do |installed|
      urls = Access.urls(installed, hostname)
      HomepageConfig::Service.new(
        name: installed.name,
        url: urls.preferred,
        description: "v#{installed.version} · store app",
        icon: "#{ViewHelpers.base_prefix}/compose-appstore-logo?store=#{URI.encode_path(installed.store)}&app=#{URI.encode_path(installed.id)}",
        check: true,
      )
    end
    HomepageConfig::Group.new(name: "Installed apps", services: services)
  end

  # The machine's own health card: failed systemd units and the last
  # hour's journal errors, linking into the dashboard for details.
  # Clicking a failed unit opens the dashboard pre-filtered to it.
  private def self.system_card(failed_units : Array(String), errors_last_hour : Int32) : String
    HTML.build do
      div(class: "homepage-system") do
        span(class: "stat-label") { text "System health" }
        if failed_units.empty?
          span(class: "homepage-system-ok") do
            span(class: "material-icons", style: "font-size: 1rem; vertical-align: middle;") do
              text "check_circle"
            end
            text " All units healthy"
          end
        else
          span(class: "homepage-system-failed") do
            span(class: "material-icons", style: "font-size: 1rem; vertical-align: middle;") do
              text "error"
            end
            text " Failed: #{failed_units.join(", ")}"
          end
        end
        span(class: "tag tag-muted") do
          text "#{errors_last_hour} errors in the last hour"
        end
      end
    end
  end

  # Machine stats from the metrics sampler's most recent point (load,
  # memory, disk, swap, network rates). Read from the in-memory tail,
  # so the strip costs nothing per poll — no extra systemctl or df.
  # Hidden entirely when the dashboard (and with it the sampler) is
  # disabled, or until the first sample exists. Links into the
  # dashboard, where the full charts live.
  private def self.machine_stats_fragment(metrics : Grafito::MetricsStore::MetricPoint?) : String
    return "" unless metrics

    base = ViewHelpers.base_prefix
    swap = metrics.swap_used_pct
    HTML.build do
      a(href: "#{base}/dashboard", class: "homepage-stats", title: "Open the dashboard for charts and details") do
        div(class: "homepage-stat") do
          span(class: "stat-label") { text "Load (1m)" }
          span(class: "stat-value") { text metrics.load1.round(2).to_s }
        end
        div(class: "homepage-stat") do
          span(class: "stat-label") { text "Memory" }
          span(class: "stat-value", style: metrics.mem_used_pct >= 90.0 ? "color: var(--err)" : "") do
            text "#{metrics.mem_used_pct.round(1)}%"
          end
        end
        div(class: "homepage-stat") do
          span(class: "stat-label") { text "Disk" }
          span(class: "stat-value", style: metrics.disk_used_pct >= 90.0 ? "color: var(--err)" : "") do
            text "#{metrics.disk_used_pct.round(1)}%"
          end
        end
        if swap
          div(class: "homepage-stat") do
            span(class: "stat-label") { text "Swap" }
            span(class: "stat-value") { text "#{swap.round(1)}%" }
          end
        end
        if (rx = metrics.net_rx_bps) && (tx = metrics.net_tx_bps)
          div(class: "homepage-stat") do
            span(class: "stat-label") { text "Net ↓/↑" }
            span(class: "stat-value") { text "#{Timeline.humanize_bytes(rx)}/s · #{Timeline.humanize_bytes(tx)}/s" }
          end
        end
      end
    end
  end

  # The weather strip: current conditions, feels-like, humidity, wind
  # and today's range. When the snapshot is nil (fetch failed) it says
  # so quietly instead of disappearing, so the layout stays stable.
  def weather_fragment(config : HomepageConfig::Weather, snapshot : Weather::Snapshot?) : String
    imperial = config.imperial?
    HTML.build do
      div(class: "homepage-weather") do
        if snapshot
          condition, icon = Weather.describe(snapshot.code)
          span(class: "material-icons homepage-weather-icon", title: condition) do
            text icon
          end
          div(class: "homepage-weather-main") do
            span(class: "homepage-weather-temp") do
              text format_temperature(snapshot.temperature, imperial)
            end
            span(class: "homepage-weather-cond") do
              text condition
            end
          end
          div(class: "homepage-weather-details") do
            if apparent = snapshot.apparent
              div do
                text "Feels like #{format_temperature(apparent, imperial)}"
              end
            end
            if humidity = snapshot.humidity
              div do
                text "Humidity #{humidity.round.to_i}%"
              end
            end
            if wind = snapshot.wind_speed
              div do
                text "Wind #{format_wind(wind, imperial)}"
              end
            end
          end
          if daily = today_range(snapshot, imperial)
            div(class: "homepage-weather-details") do
              div do
                text daily
              end
            end
          end
          span(class: "homepage-weather-location") do
            text config.location
          end
        else
          span(class: "material-icons homepage-weather-icon", title: "Weather unavailable") do
            text "cloud_off"
          end
          div(class: "homepage-weather-main") do
            span(class: "homepage-weather-cond homepage-weather-muted") do
              text "Weather unavailable"
            end
          end
        end
      end
    end
  end

  # "High 23.1° · Low 12.3°" for today, or nil when the forecast data
  # is missing (and nothing should be shown rather than placeholders).
  private def today_range(snapshot : Weather::Snapshot, imperial : Bool) : String?
    max = snapshot.temp_max
    min = snapshot.temp_min
    return if max.nil? || min.nil?
    "High #{format_temperature(max, imperial)} · Low #{format_temperature(min, imperial)}"
  end

  # One group card: a title and its services as launch rows.
  private def group_fragment(
    group : HomepageConfig::Group,
    statuses : Hash(String, ReachResult),
  ) : String
    HTML.build do
      div(class: "homepage-group") do
        div(class: "homepage-group-title") do
          text group.name
        end
        group.services.each do |service|
          html service_fragment(service, statuses[service.url]?)
        end
      end
    end
  end

  # One launch row: icon, name and optional description, optionally a
  # reachability dot, the whole row being the link to the app.
  private def service_fragment(service : HomepageConfig::Service, result : ReachResult?) : String
    HTML.build do
      tag("a", {
        "class"  => "homepage-service",
        "href"   => service.url,
        "title"  => service.description.empty? ? service.name : service.description,
        "target" => "_blank",
        "rel"    => "noopener noreferrer",
      }) do
        span(class: "homepage-service-icon") do
          html icon_fragment(service.icon)
        end
        span(class: "homepage-service-text") do
          span(class: "homepage-service-name") do
            text service.name
          end
          unless service.description.empty?
            span(class: "homepage-service-desc") do
              text service.description
            end
          end
        end
        if service.check? && result
          dot_title = result.up ? "Reachable in #{result.latency_ms} ms" : "Not reachable"
          span(class: "homepage-dot homepage-dot-#{result.up ? "up" : "down"}",
            title: dot_title) { }
          if result.up && (ms = result.latency_ms)
            span(class: "homepage-latency", title: dot_title) { text "#{ms} ms" }
          end
        end
      end
    end
  end

  # Renders the configured icon: an image URL becomes an <img>, a
  # non-ASCII string is an emoji, anything else is treated as a
  # Material Icons ligature (falling back to a generic apps icon when
  # unset). html_builder escapes both text and attributes, so even a
  # nonsensical config can only produce harmless markup.
  private def icon_fragment(icon : String) : String
    trimmed = icon.strip
    HTML.build do
      if trimmed.empty?
        span(class: "material-icons", "aria-hidden": "true") do
          text "apps"
        end
      elsif image_url?(trimmed)
        # Self-closing, so built as a raw string: tag() would append a
        # closing </img>.
        html %(<img src="#{HTML.escape(trimmed)}" alt="" loading="lazy" />)
      elsif trimmed.ascii_only?
        span(class: "material-icons", "aria-hidden": "true") do
          text trimmed
        end
      else
        span(class: "homepage-emoji", "aria-hidden": "true") do
          text trimmed
        end
      end
    end
  end

  # True for absolute http(s) URLs, the only image sources accepted.
  private def image_url?(icon : String) : Bool
    # Site-relative paths (e.g. the store logo endpoint) are images.
    return true if icon.starts_with?("/")
    uri = URI.parse(icon)
    uri.host ? {"http", "https"}.includes?(uri.scheme) : false
  rescue URI::Error
    false
  end

  # Formats a Celsius temperature, converting for imperial locales.
  def format_temperature(celsius : Float64, imperial : Bool) : String
    if imperial
      "#{(celsius * 9 / 5 + 32).round(1)}°F"
    else
      "#{celsius.round(1)}°C"
    end
  end

  # Formats a km/h wind speed, converting for imperial locales. Wind
  # is shown without decimals: it is not that precise anyway.
  def format_wind(kmh : Float64, imperial : Bool) : String
    if imperial
      "#{(kmh * 0.621371).round.to_i} mph"
    else
      "#{kmh.round.to_i} km/h"
    end
  end

  # ## Reachability checks
  #
  # Probes every service marked `check: true` concurrently (one fiber
  # each, bounded by CHECK_TIMEOUT) and reports whether it answered
  # with anything below HTTP 500. Any response counts as "up": login
  # redirects, auth walls and 404s all mean the app is alive.

  # Cached results when they are fresh enough and cover exactly the
  # currently-checked URLs; a fresh probe run otherwise.
  def service_statuses(services : Array(HomepageConfig::Service)) : Hash(String, ReachResult)
    urls = services.select(&.check?).map(&.url).uniq!
    return {} of String => ReachResult if urls.empty?

    @@status_mutex.synchronize do
      if slot = @@status_cache
        fetched_at, cached = slot
        covers_all = cached.size == urls.size && urls.all? { |url| cached.has_key?(url) }
        if covers_all && (Time.utc - fetched_at) < STATUS_CACHE_TTL
          return cached
        end
      end
    end

    statuses = probe_all(urls)
    @@status_mutex.synchronize do
      @@status_cache = {Time.utc, statuses}
    end
    statuses
  end

  private def probe_all(urls : Array(String)) : Hash(String, ReachResult)
    results = Hash(String, ReachResult).new
    channel = Channel({String, ReachResult}).new(urls.size)
    urls.each do |url|
      spawn(name: "homepage-check") do
        channel.send({url, reachable?(url)})
      end
    end
    urls.size.times do
      url, result = channel.receive
      results[url] = result
    end
    results
  end

  private def reachable?(url : String) : ReachResult
    uri = URI.parse(url)
    return ReachResult.new(up: false, latency_ms: nil) unless uri.host && {"http", "https"}.includes?(uri.scheme)
    client = HTTP::Client.new(uri)
    client.connect_timeout = CHECK_TIMEOUT
    client.read_timeout = CHECK_TIMEOUT
    # Identity encoding: only the status code matters, and Crystal's
    # transparent deflate decoding chokes on some servers' zlib
    # streams, which would read as "down".
    headers = HTTP::Headers{"Accept-Encoding" => "identity"}
    started = Time.monotonic
    response = client.get(uri.request_target, headers: headers)
    latency = (Time.monotonic - started).total_milliseconds.to_i
    ReachResult.new(up: response.status_code < 500, latency_ms: latency)
  rescue
    ReachResult.new(up: false, latency_ms: nil)
  ensure
    client.try(&.close)
  end

  # ## Fragments for the broken cases

  # Shown when there is no config file (or it is empty): the view
  # teaches how to configure itself, so enabling the view is a no-op
  # until it has something to show. When editing is allowed, the Edit
  # button doubles as "create the file" — the editor prefills this
  # example.
  def setup_hint_fragment(path : String, edit_url : String? = nil) : String
    HTML.build do
      div(class: "homepage-setup") do
        tag("h2") do
          text "Homepage"
        end
        tag("p") do
          text "Create "
          tag("code") { text path }
          text " to list your self-hosted apps here"
          if url = edit_url
            text ", or build it in the editor. For example:"
          else
            text ". For example:"
          end
        end
        tag("pre") do
          tag("code") do
            text EXAMPLE_CONFIG
          end
        end
        if url = edit_url
          html edit_button_fragment(url, label: "Open the editor")
        end
      end
    end
  end

  # Shown when the config file exists but cannot be parsed; the
  # message is YAML's own so it points at the offending line.
  def error_fragment(path : String, message : String) : String
    HTML.build do
      div(class: "homepage-setup homepage-setup-error") do
        tag("h2") do
          text "Homepage"
        end
        tag("p") do
          text "Could not read "
          tag("code") { text path }
          text ":"
        end
        tag("pre") do
          text message
        end
      end
    end
  end

  # ## Config editor
  #
  # The editor reuses the compose stack file editor's flow: a
  # monospace textarea, a Review-changes diff step, and an Apply that
  # only then writes anything. See compose_dashboard.cr for the
  # original.

  # The small button that opens the YAML editor in the inspector's
  # Detail panel. Rendered next to the page title (and in the setup
  # hint, where it doubles as "create the file").
  private def self.edit_button_fragment(edit_url : String, label : String = "Edit") : String
    HTML.build do
      button(
        class: "round-button homepage-edit-button",
        title: "Edit the homepage configuration",
        "hx-get": edit_url,
        "hx-target": "#panel-detail-content",
        "hx-swap": "innerHTML",
        "hx-indicator": "#loading-spinner",
        "hx-on:htmx:before-request": "panelSpinner('panel-detail-content')",
        "hx-on:htmx:after-request": "if(event.detail.successful){showLogPanel('detail')}else{panelError('panel-detail-content',event.detail.xhr.status);showLogPanel('detail')}",
      ) do
        span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
          text "edit"
        end
        text " #{label}"
      end
    end
  end

  # The textarea step. `error` is a validation complaint from a POST
  # (or a write failure); the draft is kept in the textarea so it can
  # be fixed in place.
  def self.homepage_editor_fragment(content : String, error : String = "") : String
    base = ViewHelpers.base_prefix
    path = Grafito.homepage_config_path
    HTML.build do
      div(class: "service-panel") do
        tag("h4") { text "Edit homepage" }
        span(class: "stat-label") { text path }
        unless error.empty?
          div(class: "appstore-errors") do
            tag("p") { text error }
          end
        end
        tag("form", {"class" => "compose-editor-form", "onsubmit" => "return false"}) do
          tag("textarea", {
            "name":        "content",
            "class":       "compose-editor-textarea",
            "spellcheck":  "false",
            "rows":        "24",
            "data-editor": "yaml",
          }) do
            text content
          end
          div(class: "service-panel-actions") do
            button(
              class: "round-button",
              "hx-post": "#{base}/homepage-edit-diff",
              "hx-include": "closest form",
              "hx-target": "#panel-detail-content",
              "hx-swap": "innerHTML",
              "hx-indicator": "#loading-spinner",
            ) do
              text "Review changes"
            end
            button(
              class: "round-button",
              type: "button",
              onclick: "closeLogPanel()",
            ) do
              text "Close"
            end
            span(class: "service-panel-hint") do
              text "Nothing is written until you apply the reviewed diff."
            end
          end
        end
      end
    end
  end

  # The review step: a unified diff of file vs. draft plus the Apply
  # button that posts the same draft again.
  def self.homepage_diff_fragment(content : String, diff : String) : String
    base = ViewHelpers.base_prefix
    path = Grafito.homepage_config_path
    HTML.build do
      div(class: "service-panel") do
        tag("h4") { text "Review changes — homepage.yml" }
        span(class: "stat-label") { text path }
        if diff.empty?
          tag("p") { text "No changes: the draft matches the file on disk." }
        else
          html diff_fragment(diff)
        end
        tag("form", {"class" => "compose-editor-form", "onsubmit" => "return false"}) do
          tag("textarea", {"name" => "content", "class" => "hidden-input"}) do
            text content
          end
          div(class: "service-panel-actions") do
            unless diff.empty?
              button(
                class: "round-button",
                "hx-post": "#{base}/homepage-edit-apply",
                "hx-include": "closest form",
                "hx-target": "#panel-detail-content",
                "hx-swap": "innerHTML",
                "hx-indicator": "#loading-spinner",
                "hx-confirm": "Write the reviewed changes to #{path}?",
              ) do
                text "Apply"
              end
            end
            button(
              class: "round-button",
              "hx-get": "#{base}/homepage-edit",
              "hx-target": "#panel-detail-content",
              "hx-swap": "innerHTML",
              "hx-indicator": "#loading-spinner",
            ) do
              text "Back to editing"
            end
          end
        end
      end
    end
  end

  # Success fragment after an apply. The zero-size div re-fetches the
  # homepage view as soon as htmx processes it, so the page behind the
  # panel updates immediately instead of waiting for the 60s poll.
  def self.homepage_applied_fragment(diff : String) : String
    base = ViewHelpers.base_prefix
    path = Grafito.homepage_config_path
    HTML.build do
      div(class: "service-panel") do
        tag("h4") { text "Homepage written" }
        span(class: "stat-label") { text path }
        tag("p") { text "Changes saved; the homepage view is refreshing behind this panel." }
        div(class: "hidden-input",
          "hx-get": "#{base}/homepage",
          "hx-target": "#homepage-view",
          "hx-swap": "innerHTML",
          "hx-trigger": "load",
          "hx-indicator": "#loading-spinner") { }
        div(class: "service-panel-actions") do
          button(
            class: "round-button",
            type: "button",
            onclick: "closeLogPanel()",
          ) do
            text "Done"
          end
        end
        unless diff.empty?
          html diff_fragment(diff)
        end
      end
    end
  end

  # A unified diff rendered as colored +/- lines.
  private def self.diff_fragment(diff : String) : String
    HTML.build do
      tag("pre", class: "compose-file-diff") do
        diff.each_line do |line|
          line = line.chomp("\n")
          kind = line.starts_with?("+") && !line.starts_with?("+++") ? "add" : (line.starts_with?("-") && !line.starts_with?("---") ? "del" : "ctx")
          span(class: "diff-#{kind}") { text line + "\n" }
        end
      end
    end
  end

  EXAMPLE_CONFIG = <<-YAML
    title: Homelab

    # Services declared with only a port are reached at
    # http://<hostname>:<port>.
    hostname: rocky

    weather:
      latitude: -34.9
      longitude: -56.16
      location: Montevideo

    groups:
      - name: Media
        services:
          - name: Jellyfin
            port: 8096
            description: Movies and series
            icon: play_circle
            check: true
      - name: Utilities
        services:
          - name: Home Assistant
            url: https://ha.example.com
    YAML

  # ## Routes
  #
  # The view owns its endpoint, like every other view module. Adding
  # a view means one module with a `register_routes` method, a
  # require, a call from `Grafito.register_routes`, and the small
  # frontend addition in index.html's VIEWS registry.
  private def self.route_path(path : String) : String
    Grafito.route_path(path)
  end

  def self.register_routes
    # ## The `/homepage` endpoint
    #
    # Returns the homepage HTML fragment for HTMX: the weather widget
    # (when configured), the service groups and their status dots.
    # The frontend polls it every 60 seconds.
    get route_path("homepage") do |env|
      unless Grafito.homepage_enabled?
        env.response.status_code = 404
        next "Homepage view is disabled."
      end
      env.response.content_type = "text/html"
      render_config_fragment(Access.hostname_from(env.request.headers["Host"]?))
    end

    # ## The editor endpoints
    #
    # GET opens the textarea (current effective config), POST diff
    # reviews, POST apply validates and writes. All three share the
    # actions gate: editing writes to disk, exactly like the compose
    # stack file editor.

    get route_path("homepage-edit") do |env|
      if complaint = homepage_edit_gate
        halt env, status_code: 403, response: complaint
      end
      env.response.content_type = "text/html"
      homepage_editor_fragment(editor_content)
    end

    post route_path("homepage-edit-diff") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      if complaint = homepage_edit_gate
        halt env, status_code: 403, response: complaint
      end
      content = env.params.body["content"]?.to_s
      if content.bytesize > ComposeDashboard::MAX_EDIT_FILE_BYTES
        halt env, status_code: 413, response: "Draft too large (limit #{ComposeDashboard::MAX_EDIT_FILE_BYTES // 1024} KiB)."
      end
      if complaint = validate_homepage_draft(content)
        env.response.content_type = "text/html"
        next homepage_editor_fragment(content, complaint)
      end
      env.response.content_type = "text/html"
      homepage_diff_fragment(content, ComposeDashboard.unified_diff(homepage_raw_content, content))
    end

    post route_path("homepage-edit-apply") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      if complaint = homepage_edit_gate
        halt env, status_code: 403, response: complaint
      end
      content = env.params.body["content"]?.to_s
      if content.bytesize > ComposeDashboard::MAX_EDIT_FILE_BYTES
        halt env, status_code: 413, response: "Draft too large (limit #{ComposeDashboard::MAX_EDIT_FILE_BYTES // 1024} KiB)."
      end
      if complaint = validate_homepage_draft(content)
        env.response.content_type = "text/html"
        next homepage_editor_fragment(content, complaint)
      end

      diff = ""
      error = ""
      {% if flag?(:demo_mode) %}
        # Nothing is written on the demo build; the flow is complete
        # so it can be walked end to end.
        diff = ComposeDashboard.unified_diff(homepage_raw_content, content)
      {% else %}
        path = Grafito.homepage_config_path
        begin
          diff = write_homepage_config(path, content)
        rescue ex : IO::Error
          # Read-only mount or missing permissions: say so instead of
          # a raw stack trace, and keep the draft editable.
          error = "#{path} is not writable (read-only mount?): #{ex.message}"
        end
      {% end %}

      env.response.content_type = "text/html"
      if error.empty?
        homepage_applied_fragment(diff)
      else
        homepage_editor_fragment(content, error)
      end
    end
  end

  # The editor's shared gate: the view must be on and actions (which
  # cover writing to the host) must be allowed.
  private def self.homepage_edit_gate : String?
    return "Homepage view is disabled." unless Grafito.homepage_enabled?
    return "Actions are not allowed here." unless Grafito.actions_available?
    nil
  end

  # The textarea's starting point. Normally the file's own text, so
  # the author's comments and layout survive; when the settings
  # overlay is set — or the file is missing or broken — the effective
  # config is serialized instead, so the draft carries every value
  # that currently governs the page (and applying it retires the
  # overlay without losing anything).
  private def self.editor_content : String
    {% if flag?(:demo_mode) %}
      return FakeHomepageData.config.to_yaml
    {% end %}
    path = Grafito.homepage_config_path
    raw = File.exists?(path) ? File.read(path) : ""
    return EXAMPLE_CONFIG if raw.strip.empty?
    begin
      overlay = SettingsStore.load(Grafito.data_dir).homepage
      return raw unless overlay.try(&.set?)
      config = HomepageConfig::Config.load(path)
      config.apply_overlay(overlay)
      config.to_yaml
    rescue ex
      # Broken file: offer it raw so it can be repaired in the editor.
      Log.warn { "Homepage editor fell back to the raw file: #{ex.message}" }
      raw
    end
  end

  # The file's text as it is on disk ("" when absent), for diffing.
  private def self.homepage_raw_content : String
    {% if flag?(:demo_mode) %}
      FakeHomepageData.config.to_yaml
    {% else %}
      path = Grafito.homepage_config_path
      File.exists?(path) ? File.read(path) : ""
    {% end %}
  end

  # Parses the draft exactly the way the renderer will, so an apply
  # can never write a config the page cannot render. Returns a human
  # complaint, or nil when the draft is sound.
  private def self.validate_homepage_draft(content : String) : String?
    return "The draft is empty." if content.strip.empty?
    begin
      HomepageConfig::Config.from_yaml(content)
    rescue ex : YAML::ParseException
      return "YAML: #{ex.message}"
    rescue ex : ArgumentError
      # from resolve_urls! during after_initialize.
      return ex.message || "Invalid draft."
    rescue ex
      return "#{ex.class.name}: #{ex.message}"
    end
    nil
  end

  # Writes the reviewed draft: the compose editor's apply_stack_file
  # does the rolling backup and atomic rename. The draft already
  # carries the overlay values (see editor_content), so the overlay is
  # retired here and the file becomes the whole truth. Returns the
  # unified diff of what was written.
  private def self.write_homepage_config(path : String, content : String) : String
    Dir.mkdir_p(File.dirname(path))
    diff = ComposeDashboard.apply_stack_file(path, content)
    settings = SettingsStore.load(Grafito.data_dir)
    if settings.homepage.try(&.set?)
      settings.homepage = nil
      SettingsStore.save(Grafito.data_dir, settings)
      Log.info { "Homepage overlay retired into #{path}" }
    end
    Log.info { "Homepage config written: #{path}" }
    diff
  end

  # The installed store apps for the homepage's discovery group.
  # Empty when the app store is disabled.
  private def self.installed_apps_for_homepage : Array(AppStore::InstalledApp)
    return [] of AppStore::InstalledApp unless Grafito.apps_enabled?
    {% if flag?(:demo_mode) %}
      FakeAppStore.installed
    {% else %}
      AppStore.installed(Grafito.data_dir)
    {% end %}
  end

  # The system health data for the homepage card: failed systemd
  # units and the last hour's error-severity journal entries.
  private def self.system_health_data : {Array(String), Int32}
    failed = SystemStatus.unit_states.select(&.failed?).map(&.unit)
    errors = (Journalctl.query(since: "-1h", priority: "3", lines: 500) || [] of Journalctl::LogEntry)
      .size
    {failed, errors}
  end

  # The config that governs the page: the YAML file (when present)
  # with the settings-store overlay applied on top of it.
  def self.effective_config : HomepageConfig::Config
    path = Grafito.homepage_config_path
    config =
      if File.exists?(path)
        HomepageConfig::Config.load(path)
      else
        HomepageConfig::Config.from_yaml("{}")
      end
    config.apply_overlay(SettingsStore.load(Grafito.data_dir).homepage)
    config
  end

  # Loads, renders, and degrades: a missing or empty config renders
  # setup instructions, a broken one renders the parser's complaint.
  private def self.render_config_fragment(hostname : String? = nil) : String
    path = Grafito.homepage_config_path
    edit_url = Grafito.actions_available? ? "#{ViewHelpers.base_prefix}/homepage-edit" : nil

    {% if flag?(:demo_mode) %}
      # The demo build has no real config file; it ships a fake
      # homepage so the view shows its full shape. Weather still comes
      # from the live API when the demo has internet, and the status
      # dots are fixed so every state is visible.
      config = FakeHomepageData.config
      statuses = FakeHomepageData.statuses
      weather_snapshot = config.weather.try do |weather_config|
        Weather.snapshot(weather_config.latitude, weather_config.longitude)
      end
      failed_units, errors_last_hour = system_health_data
      installed_apps = installed_apps_for_homepage
      return render_html(config, weather_snapshot, statuses, failed_units, errors_last_hour,
        metrics: Grafito.metrics_store.try(&.latest), installed_apps: installed_apps, hostname: hostname,
        edit_url: edit_url)
    {% end %}

    # The file supplies the groups and services; the settings store
    # can override title, hostname and weather on top of it (and can
    # carry the whole page when there is no file at all).
    config = effective_config
    return setup_hint_fragment(path, edit_url) if config.empty?

    weather_snapshot = config.weather.try do |weather_config|
      Weather.snapshot(weather_config.latitude, weather_config.longitude)
    end
    statuses = service_statuses(config.groups.flat_map(&.services))
    failed_units, errors_last_hour = system_health_data
    installed_apps = installed_apps_for_homepage
    render_html(config, weather_snapshot, statuses, failed_units, errors_last_hour,
      metrics: Grafito.metrics_store.try(&.latest), installed_apps: installed_apps, hostname: hostname,
      edit_url: edit_url)
  rescue ex
    # Body locals are nilable in rescue, so the path is read again.
    message = ex.message || ex.class.name
    Log.error(exception: ex) { "Homepage fragment failed: #{message}" }
    error_fragment(Grafito.homepage_config_path, message)
  end
end
