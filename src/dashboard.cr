# # Dashboard
#
# The server dashboard is an HTMX fragment: the frontend polls
# `GET /dashboard` every 30 seconds and swaps it into `#dashboard-view`.
# This module renders that fragment: health cards, a small history
# chart, and the unit table.
#
# The unit names are clickable using the same `setUnitFilterAndTrigger`
# JavaScript the log table uses, so clicking a unit on the dashboard
# jumps straight into its logs. When unit actions are enabled
# (`--enable-actions`), each row also gets start/stop/restart buttons
# with htmx's built-in confirm dialog.
#
# Because html_builder's DSL only exists inside an `HTML.build` block,
# the helper methods each return an HTML string built in their own
# block; the top-level renderer embeds them with `html`.

require "html_builder"
require "log"
require "csv"

require "./system_status"
require "./metrics_store"
require "./ai/config"
require "./ai/request"

require "./view_helpers"

module Dashboard
  extend self
  include ViewHelpers

  Log = ::Log.for(self)

  # Renders the dashboard fragment. `history` may be empty (e.g. the
  # sampler just started). `sort_by`/`sort_order` control the unit table
  # ordering, `unit_filter` narrows the table, and `since_text` is the
  # selected time window (used by the history chart and error count).
  def render_html(
    snapshot : SystemStatus::Snapshot,
    history : Array(Grafito::MetricsStore::MetricPoint),
    errors_last_hour : Int32,
    oom_kills : Int32 = 0,
    enable_actions : Bool = false,
    sort_by : String? = nil,
    sort_order : String? = nil,
    unit_filter : String? = nil,
    since_text : String? = nil,
    unit_flags : Hash(String, SystemStatus::UnitFileFlags) = {} of String => SystemStatus::UnitFileFlags,
    severity_buckets : Array(Timeline::TimelinePoint) = [] of Timeline::TimelinePoint,
    unit_usage : Hash(String, SystemStatus::UnitResourceUsage) = {} of String => SystemStatus::UnitResourceUsage,
  ) : String
    # Units arrive sorted by name from SystemStatus; apply the requested
    # column sort on top (defaulting to name, ascending).
    sort_key = normalize_sort_key(sort_by)
    ascending = normalize_sort_order(sort_order) == "asc"
    units = sort_units(filter_units(snapshot.units, unit_filter), sort_key, ascending)

    HTML.build do
      # One form wrapping the whole fragment so each control's
      # hx-include="closest form" sends the complete state (filter,
      # window, sort) with every request.
      tag("form", {"class" => "dashboard-form", "onsubmit" => "return false"}) do
        div(class: "dashboard-grid") do
          html card("Uptime", format_uptime(snapshot.uptime_sec))
          html card("Load (1m)", snapshot.load1.round(2).to_s)
          html card("Memory", "#{snapshot.mem_used_pct.round(1)}%", warn: snapshot.mem_used_pct >= 90.0)
          html swap_card(snapshot)
          html card("Disk", "#{snapshot.disk_used_pct.round(1)}%", warn: snapshot.disk_used_pct >= 90.0)
          html card("Failed units", snapshot.units_failed.to_s, warn: snapshot.units_failed > 0)
          html card("Services", units.size.to_s)
          html card("Errors (#{window_label(since_text)})", errors_last_hour.to_s, warn: errors_last_hour > 20)
          html card("OOM (#{window_label(since_text)})", oom_kills.to_s, warn: oom_kills > 0)
        end

        div(class: "dashboard-history") do
          if history.size >= 2
            html Timeline.combined_legend
            html Timeline.generate_combined_svg(history, severity_buckets)
          end
          # Points from before the network field existed parse as nil,
          # so only draw the chart when the window actually carries
          # network samples.
          if history.count { |point| point.net_rx_bps || point.net_tx_bps } >= 2
            html Timeline.network_legend
            html Timeline.generate_network_svg(history)
          end
          a(href: export_csv_url(since_text), title: "Download the raw samples for this window as CSV", class: "muted-note") do
            text "Export CSV"
          end
          html window_select(since_text)
        end

        input(type: "hidden", name: "sort_by", value: sort_key)
        input(type: "hidden", name: "sort_order", value: ascending ? "asc" : "desc")

        table(class: "striped dashboard-units") do
          thead do
            tr do
              html sortable_header("State", "state", sort_key, ascending)
              html sortable_header("Sub", "sub", sort_key, ascending)
              html sortable_header("Description", "description", sort_key, ascending)
              th { text "CPU" }
              th { text "MEM" }
              html sortable_header("Unit", "unit", sort_key, ascending)
              if enable_actions
                th { text "Actions" }
              end
            end
          end
          tbody do
            if units.empty?
              tr do
                td(colspan: enable_actions ? "7" : "6", style: "text-align: center; padding: 1em;") do
                  text normalize_filter(unit_filter).empty? ? "No systemd units found." : "No units match the filter."
                end
              end
            else
              units.each do |unit_state|
                html unit_row(unit_state, enable_actions, unit_flags, unit_usage[unit_state.unit]?)
              end
            end
          end
        end
      end
    end
  end

  # The time window selector, overlaid on the top-right corner of the
  # history chart: the chart is the time control's natural home.
  private def window_select(since_text : String?) : String
    HTML.build do
      tag("select", {
        "name"         => "since",
        "class"        => "dashboard-window-select",
        "title"        => "Time window for the history chart and error count",
        "aria-label"   => "Time window for the history chart and error count",
        "hx-get"       => "dashboard",
        "hx-trigger"   => "change",
        "hx-target"    => "#dashboard-view",
        "hx-swap"      => "innerHTML",
        "hx-include"   => "closest form",
        "hx-indicator" => "#loading-spinner",
      }) do
        {"-15m" => "15m", "-1h" => "1h", "-6h" => "6h", "-12h" => "12h", "-1d" => "24h", "-7d" => "7d"}.each do |value, label|
          attributes = {"value" => value}
          attributes["selected"] = "selected" if value == normalize_window(since_text)
          tag("option", attributes) do
            text label
          end
        end
      end
    end
  end

  # The service filter input lives in the page's topbar (outside this
  # fragment, so it survives auto-refreshes); its value arrives here as
  # the `unit` query parameter on every dashboard request.

  # Normalizes the unit filter to a plain string.
  private def normalize_filter(unit_filter : String?) : String
    (unit_filter || "").strip
  end

  # Maps the time window to a known value, defaulting to 6 hours.
  private def normalize_window(since_text : String?) : String
    window = since_text.try(&.strip) || ""
    case window
    when "-15m", "-1h", "-12h", "-1d", "-7d" then window
    else                                          "-6h"
    end
  end

  # Short label for the errors card, derived from the window.
  private def window_label(since_text : String?) : String
    normalize_window(since_text).lstrip('-')
  end

  # Narrows the unit table to units where the filter text matches any
  # displayed column: name, description, state or sub-state. So typing
  # "failed" lists failed units, "running" lists live ones, etc. An
  # empty filter keeps everyone.
  private def filter_units(
    units : Array(SystemStatus::UnitState),
    unit_filter : String?,
  ) : Array(SystemStatus::UnitState)
    filter = normalize_filter(unit_filter).downcase
    return units if filter.empty?

    units.select do |unit_state|
      [unit_state.unit, unit_state.description, unit_state.active_state, unit_state.sub_state]
        .any?(&.downcase.includes?(filter))
    end
  end

  # Maps a requested sort column to a known key, defaulting to "unit".
  private def normalize_sort_key(sort_by : String?) : String
    case sort_by
    when "state"       then "state"
    when "sub"         then "sub"
    when "description" then "description"
    else                    "unit"
    end
  end

  # Normalizes the requested order, defaulting to ascending.
  private def normalize_sort_order(sort_order : String?) : String
    sort_order == "desc" ? "desc" : "asc"
  end

  # Sorts units by the given key, case-insensitively. Failed units are
  # kept together by their own state value, like any other sort.
  private def sort_units(
    units : Array(SystemStatus::UnitState),
    sort_key : String,
    ascending : Bool,
  ) : Array(SystemStatus::UnitState)
    sorted = units.sort_by do |unit_state|
      value = case sort_key
              when "state"       then unit_state.active_state
              when "sub"         then unit_state.sub_state
              when "description" then unit_state.description
              else                    unit_state.unit
              end
      value.downcase
    end
    ascending ? sorted : sorted.reverse
  end

  # A clickable table header for one sortable column. The click goes
  # through sortDashboard() in the page JavaScript, which remembers the
  # choice across the 30s auto-refresh polls. The active column shows a
  # direction arrow, mirroring the log table's sort indicators.
  private def sortable_header(
    label : String,
    key : String,
    current_sort_key : String,
    ascending : Bool,
  ) : String
    indicator = if current_sort_key == key
                  icon = ascending ? "arrow_upward" : "arrow_downward"
                  %q( <span class="material-icons" aria-hidden="true" style="font-size: inherit; vertical-align: middle;">) + icon + "</span>"
                else
                  ""
                end
    HTML.build do
      th({
        "style"   => "cursor: pointer; vertical-align: middle;",
        "onclick" => "sortDashboard('#{key}')",
        "title"   => "Sort by #{label.downcase}",
      }) do
        text label
        html indicator
      end
    end
  end

  # One health card. Reuses the log view's `.stat` styling.

  # Swap usage card. Machines without swap render an em-dash — that is
  # a legitimate setup, not a zero-percent-full disk.
  private def swap_card(snapshot : SystemStatus::Snapshot) : String
    swap = snapshot.swap_used_pct
    card("Swap", swap ? "#{swap.round(1)}%" : "—", warn: swap ? swap >= 90.0 : false)
  end

  # Renders the service detail fragment for the right sidebar's Detail
  # tab: unit identity and state pills, recent error count, unit actions
  # (when enabled) and a call to jump into the unit's logs.
  def unit_details_fragment(
    unit_state : SystemStatus::UnitState,
    enable_actions : Bool = false,
    errors_last_hour : Int32 = 0,
    unit_flags : Hash(String, SystemStatus::UnitFileFlags) = {} of String => SystemStatus::UnitFileFlags,
  ) : String
    flags = unit_flags[unit_state.unit]?
    can_start = flags.nil? ? true : flags.can_start
    lifecycle = lifecycle_actions(unit_state, can_start)
    enablement = enablement_action(unit_state, flags)
    HTML.build do
      div(class: "service-panel") do
        tag("h4") do
          text unit_state.unit
        end
        div(class: "service-panel-pills") do
          html state_pill(unit_state.active_state)
          html state_pill(unit_state.sub_state)
        end
        unless unit_state.description.empty?
          tag("p") do
            text unit_state.description
          end
        end

        div(class: "service-panel-info") do
          div do
            span(class: "stat-label") { text "Load state" }
            span { text unit_state.load_state }
          end
          div do
            span(class: "stat-label") { text "Errors (1h)" }
            span(class: errors_last_hour > 0 ? "stat-value stat-error" : "stat-value") do
              text errors_last_hour.to_s
            end
          end
        end

        if enable_actions
          div(class: "service-panel-actions") do
            lifecycle.each do |item|
              html action_button(unit_state.unit, item[:action], item[:icon], "#panel-detail-content", true)
            end
            if enablement
              html action_button(unit_state.unit, enablement[:action], enablement[:icon], "#panel-detail-content", true)
            end
            span(class: "service-panel-hint") { text "systemctl actions" }
          end
        end

        if Grafito.ai_provider
          div(class: "service-panel-ai") do
            button(
              {
                "class"        => "service-panel-explain",
                "title"        => "Ask the AI to explain this unit's state and recent logs",
                "hx-post"      => unit_explain_url(unit_state.unit),
                "hx-target"    => "#service-ai-content",
                "hx-swap"      => "innerHTML",
                "hx-indicator" => "#loading-spinner",
              }
            ) do
              span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
                text "psychology"
              end
              text " Explain this unit (AI)"
            end
            div(id: "service-ai-content") { }
          end
        end

        button(
          class: "service-panel-viewlogs",
          onclick: "return setUnitFilterAndTrigger(#{unit_state.unit.to_json});",
        ) do
          span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
            text "article"
          end
          text " View logs for this unit"
        end
      end
    end
  end

  # The AI explanation fragment swapped into #service-ai-content. The
  # raw model output rides along hidden; page JavaScript renders it as
  # markdown with marked after the swap.
  def unit_ai_fragment(content : String) : String
    HTML.build do
      div(class: "service-ai-answer") do
        div(class: "ai-answer-raw", style: "display: none") do
          text content
        end
        div(class: "ai-answer-rendered ai-markdown-content") { }
      end
    end
  end

  private def unit_explain_url(unit_name : String) : String
    base = base_prefix
    "#{base}/unit-explain?name=#{URI.encode_path(unit_name)}"
  end

  # CSV download link for the selected history window.
  private def export_csv_url(since_text : String?) : String
    base = base_prefix
    "#{base}/status/history/export?since=#{URI.encode_path(since_text.presence || "-6h")}"
  end

  private def unit_row(
    unit_state : SystemStatus::UnitState,
    enable_actions : Bool,
    unit_flags : Hash(String, SystemStatus::UnitFileFlags),
    usage : SystemStatus::UnitResourceUsage?,
  ) : String
    HTML.build do
      # The row class carries the state color as --tag-color, which the
      # CSS turns into the left-side stripe, like the log view's
      # severity stripes. Failed rows keep an extra tint.
      row_class = "du-state-#{unit_state.active_state}"
      row_class = "#{row_class} dashboard-unit-failed" if unit_state.failed?
      # Clicking anywhere on the row opens the service panel (the
      # sidebar's Detail tab), like clicking a log row opens the entry
      # inspector.
      row_attributes = {
        "class"                     => row_class,
        "tabindex"                  => "0",
        "title"                     => "Show details for #{unit_state.unit}",
        "hx-get"                    => unit_details_url(unit_state.unit),
        "hx-target"                 => "#panel-detail-content",
        "hx-swap"                   => "innerHTML",
        "hx-on:htmx:before-request" => "panelSpinner('panel-detail-content')",
        "hx-on:htmx:after-request"  => "if(event.detail.successful){showLogPanel('detail')}else{panelError('panel-detail-content',event.detail.xhr.status);showLogPanel('detail')}",
      }
      tr(row_attributes) do
        td(class: "dashboard-state-cell") do
          html state_pill(unit_state.active_state)
        end
        td(class: "dashboard-sub-cell") do
          html state_pill(unit_state.sub_state)
        end
        description_attrs = {} of String => String
        description_attrs["title"] = unit_state.description unless unit_state.description.empty?
        td(description_attrs) do
          text unit_state.description
        end
        tag("td", {"class" => "du-res", "style" => "text-align: right; font-variant-numeric: tabular-nums;"}) do
          text usage.try(&.cpu_pct).try { |pct| "#{pct.round(1)}%" } || "—"
        end
        tag("td", {"class" => "du-res", "style" => "text-align: right; font-variant-numeric: tabular-nums;"}) do
          text usage.try(&.mem_mb).try { |mb| mb >= 1024 ? "#{(mb / 1024).round(1)} GB" : "#{mb.round.to_i} MB" } || "—"
        end
        td(title: unit_state.unit) do
          # The unit name keeps its direct behavior (jump into the unit's
          # logs); stop propagation so it doesn't also open the panel.
          js_arg_unit_name = unit_state.unit.to_json
          a(href: "#", onclick: "event.stopPropagation();return setUnitFilterAndTrigger(#{js_arg_unit_name});") do
            text unit_state.unit
          end
        end
        if enable_actions
          html action_cell(unit_state, unit_flags)
        end
      end
    end
  end

  # State-appropriate action buttons for one unit row, wrapped in their
  # table cell. Like the panel: start an inactive unit, stop/restart an
  # active one, recover a failed one, and enable/disable according to
  # its unit file state. Templates (foo@.service) and masked units offer
  # nothing because everything would fail.
  private def action_cell(
    unit_state : SystemStatus::UnitState,
    unit_flags : Hash(String, SystemStatus::UnitFileFlags),
  ) : String
    unit_name = unit_state.unit
    flags = unit_flags[unit_name]?
    if unit_name.ends_with?("@.service") || flags.try(&.file_state) == "masked"
      # Templates can't be operated on without an instance, and masked
      # units refuse everything: no buttons instead of guaranteed
      # failures.
      return HTML.build { tag("td") { } }
    end
    # CanStart is systemd's own verdict on whether the unit may be
    # started (RefuseManualStart, not-found, templates, masked...).
    can_start = flags.nil? ? true : flags.can_start

    HTML.build do
      td(class: "dashboard-action-cell") do
        lifecycle_actions(unit_state, can_start).each do |item|
          html action_button(unit_name, item[:action], item[:icon], "#dashboard-view", false)
        end
        if enablement = enablement_action(unit_state, flags)
          html action_button(unit_name, enablement[:action], enablement[:icon], "#dashboard-view", false)
        end
      end
    end
  end

  # The lifecycle actions that make sense for a unit in its current
  # state: start an inactive unit, stop/restart an active one, recover a
  # failed one. CanStart=no (RefuseManualStart, not-found, masked...)
  # removes the start-flavored buttons entirely. Computed before any
  # HTML.build block, where module helpers aren't reachable.
  private def lifecycle_actions(
    unit_state : SystemStatus::UnitState,
    can_start : Bool,
  ) : Array(NamedTuple(action: String, icon: String))
    actions = [] of NamedTuple(action: String, icon: String)
    case unit_state.active_state
    when "active", "activating", "reloading"
      actions << {action: "stop", icon: "stop"}
      actions << {action: "restart", icon: "restart_alt"} if can_start
    when "failed"
      actions << {action: "start", icon: "play_arrow"} if can_start
      actions << {action: "restart", icon: "restart_alt"} if can_start
    else
      actions << {action: "start", icon: "play_arrow"} if can_start
    end
    actions
  end

  # The enablement action that applies to the unit's unit file state,
  # or nil when none does (static, masked, generated, unknown...).
  private def enablement_action(
    unit_state : SystemStatus::UnitState,
    flags : SystemStatus::UnitFileFlags?,
  ) : NamedTuple(action: String, icon: String)?
    case flags.try(&.file_state)
    when "enabled"  then {action: "disable", icon: "link_off"}
    when "disabled" then {action: "enable", icon: "link"}
    end
  end

  # One icon-only action button. `target` decides what gets refreshed:
  # the whole dashboard (table) or just the service panel. `from_panel`
  # tells the action endpoint to answer with a refreshed panel.
  private def action_button(
    unit_name : String,
    action : String,
    icon : String,
    target : String,
    from_panel : Bool,
  ) : String
    HTML.build do
      confirm_text = "#{action[0].upcase}#{action[1..]} unit #{unit_name}?"
      attributes = {
        "class"        => "round-button",
        "title"        => "#{action[0].upcase}#{action[1..]} #{unit_name}",
        "aria-label"   => "#{action[0].upcase}#{action[1..]} #{unit_name}",
        "hx-post"      => "#{build_action_url(unit_name, action)}#{from_panel ? "?from=panel" : ""}",
        "hx-target"    => target,
        "hx-swap"      => "innerHTML",
        "hx-confirm"   => confirm_text,
        "hx-indicator" => "#loading-spinner",
      }
      button(attributes) do
        span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
          text icon
        end
      end
    end
  end

  # Renders a failed unit action as an error block for the service
  # panel. The message is systemd's own (e.g. "Access denied"), shown
  # verbatim so the user can act on it.

  private def unit_details_url(unit_name : String) : String
    base = base_prefix
    "#{base}/unit-details?name=#{URI.encode_path(unit_name)}"
  end

  # Renders a state or sub-state value as a pill matching the log view's
  # priority tags: same shape, color chosen by semantic value.
  private def state_pill(value : String) : String
    color = case value
            when "active", "running"       then "ok"
            when "failed"                  then "err"
            when "activating", "reloading" then "warn"
            when "exited"                  then "info"
            when "dead", "inactive"        then "debug"
            else                                "muted"
            end
    pill(value, color)
  end

  # Start/stop/restart buttons. htmx's hx-confirm attribute supplies the
  # confirmation dialog; the POST swaps the refreshed dashboard in.

  private def build_action_url(unit_name : String, action : String) : String
    base = base_prefix
    "#{base}/unit/#{URI.encode_path(unit_name)}/#{action}"
  end

  # Formats an uptime in seconds as e.g. "3d 4h" or "2h 15m".
  def format_uptime(seconds : Int64) : String
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    if days > 0
      "#{days}d #{hours}h"
    elsif hours > 0
      "#{hours}h #{minutes}m"
    else
      "#{minutes}m"
    end
  end

  # ## Routes
  #
  # The dashboard view owns its endpoints: adding a view to grafito
  # means creating a module like this one with a `register_routes`
  # method, requiring it in grafito.cr and calling it from
  # `Grafito.register_routes`. Everything else - the frontend switcher
  # entry, the view fragment div and the log-chrome hiding CSS - is a
  # small, purely additive change.
  # Route helpers of the enclosing Grafito module, re-exposed here so
  # the route bodies below can use them verbatim.
  private def self.optional_query_param(env : HTTP::Server::Context, key : String) : String?
    Grafito.optional_query_param(env, key)
  end

  private def self.route_path(path : String) : String
    Grafito.route_path(path)
  end

  def self.register_routes
    # ## The `/status` endpoint
    #
    # Returns the current system snapshot (metrics + unit states) plus a
    # bounded journal error count, as JSON.
    #
    # Example usage:
    # ```text
    # GET /status
    # ```
    get route_path("status") do |env|
      unless Grafito.dashboard_enabled?
        env.response.content_type = "application/json"
        env.response.status_code = 404
        next {error: "Dashboard is disabled"}.to_json
      end

      snapshot = SystemStatus.snapshot
      env.response.content_type = "application/json"
      {
        timestamp:        snapshot.timestamp,
        load1:            snapshot.load1,
        mem_used_pct:     snapshot.mem_used_pct,
        disk_used_pct:    snapshot.disk_used_pct,
        uptime_sec:       snapshot.uptime_sec,
        units_total:      snapshot.units_total,
        units_failed:     snapshot.units_failed,
        errors_last_hour: recent_error_count("-1h"),
        units:            snapshot.units,
      }.to_json
    end

    # ## The `/status/history` endpoint
    #
    # Returns the sampled metrics history as JSON. Accepts the usual
    # relative `since` vocabulary (e.g. `?since=-1d`).
    get route_path("status/history") do |env|
      unless Grafito.dashboard_enabled?
        env.response.content_type = "application/json"
        env.response.status_code = 404
        next {error: "Dashboard is disabled"}.to_json
      end

      since_text = optional_query_param(env, "since") || "-1h"
      since = parse_since(since_text)
      if since.nil?
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next {error: "Invalid 'since' parameter: #{since_text}"}.to_json
      end

      store = Grafito.metrics_store
      points = if max_points = optional_query_param(env, "max_points").try(&.to_i?)
                 store ? store.history_downsampled(since, max_points.clamp(10, 5000)) : [] of Grafito::MetricsStore::MetricPoint
               else
                 store ? store.history(since) : [] of Grafito::MetricsStore::MetricPoint
               end
      env.response.content_type = "application/json"
      {points: points}.to_json
    end

    # ## The `/status/history/export` endpoint
    #
    # Downloads the sampled metrics history since the given relative
    # time as a CSV attachment — full fidelity (no downsampling), the
    # machine-readable counterpart of the dashboard charts.
    get route_path("status/history/export") do |env|
      unless Grafito.dashboard_enabled?
        env.response.status_code = 404
        next "Dashboard is disabled."
      end

      since_text = optional_query_param(env, "since") || "-1h"
      since = parse_since(since_text)
      if since.nil?
        env.response.content_type = "text/plain"
        env.response.status_code = 400
        next "Invalid 'since' parameter: #{since_text}"
      end

      points = Grafito.metrics_store.try(&.history(since)) || [] of Grafito::MetricsStore::MetricPoint
      env.response.content_type = "text/csv"
      env.response.headers["Content-Disposition"] = "attachment; filename=\"grafito-metrics-#{since_text.delete("-")}.csv\""
      metrics_csv(points)
    end

    # ## The `/dashboard` endpoint
    #
    # Returns the dashboard HTML fragment for HTMX: health cards, history
    # chart and the unit table. The frontend polls it every 30 seconds.
    # Parameters:
    # * `sort_by` (unit, state, sub, description) and `sort_order`
    #   (asc/desc) control the unit table ordering.
    # * `unit` filters the unit table by name or description.
    # * `since` sets the time window for the history chart and the
    #   error count (e.g. -15m, -1h, -6h, -1d, -7d; default -6h).
    get route_path("dashboard") do |env|
      unless Grafito.dashboard_enabled?
        env.response.status_code = 404
        next "Dashboard is disabled."
      end
      sort_by = optional_query_param(env, "sort_by")
      sort_order = optional_query_param(env, "sort_order")
      unit_filter = optional_query_param(env, "unit")
      since_text = optional_query_param(env, "since")
      # One snapshot per poll: it feeds both the flags query and the
      # fragment, instead of systemctl list-units running twice.
      snapshot = SystemStatus.snapshot
      unit_flags = Grafito.enable_actions? ? SystemStatus.unit_flags_map(snapshot) : {} of String => SystemStatus::UnitFileFlags
      env.response.content_type = "text/html"
      render_dashboard_fragment(sort_by, sort_order, unit_filter, since_text, unit_flags, snapshot)
    end

    # ## The `/unit-details` endpoint
    #
    # Returns the service detail fragment for the right sidebar's Detail
    # tab: state pills, recent error count, optional unit actions and a
    # "view logs" call.
    #
    # Example usage:
    # ```text
    # GET /unit-details?name=nginx.service
    # ```
    get route_path("unit-details") do |env|
      unless Grafito.dashboard_enabled?
        env.response.status_code = 404
        next "Dashboard is disabled."
      end

      name = optional_query_param(env, "name")
      if name.nil? || name.empty? || name.starts_with?('-') || !name.matches?(/^[\w.@-]+$/)
        halt env, status_code: 400, response: "Missing or invalid unit name."
      end

      unit_state = SystemStatus.unit_states.find do |unit|
        unit.unit == name || unit.unit == "#{name}.service"
      end
      unless unit_state
        env.response.status_code = 404
        next "Unit '#{HTML.escape(name)}' not found."
      end

      env.response.content_type = "text/html"
      Dashboard.unit_details_fragment(
        unit_state,
        Grafito.enable_actions?,
        unit_error_count(unit_state.unit),
        Grafito.enable_actions? ? SystemStatus.unit_flags_map : {} of String => SystemStatus::UnitFileFlags,
      )
    end

    # ## The `/unit-explain` endpoint
    #
    # `POST /unit-explain?name=<unit>` asks the configured AI provider
    # to explain the unit's current state using its recent journal
    # entries. Returns an HTML fragment for the sidebar. 503 when no AI
    # provider is configured, 404 for unknown units.
    post route_path("unit-explain") do |env|
      unless Grafito.dashboard_enabled?
        env.response.status_code = 404
        next "Dashboard is disabled."
      end

      # Read-only, but a cross-site page could still burn the
      # operator's paid AI quota; same gate as the action routes.
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end

      provider = Grafito.ai_provider
      unless provider
        env.response.content_type = "application/json"
        env.response.status_code = 503
        next {error: "AI features are disabled. Configure a provider key to enable explanations."}.to_json
      end

      name = optional_query_param(env, "name")
      if name.nil? || name.empty? || name.starts_with?('-') || !name.matches?(/^[\w.@-]+$/)
        env.response.content_type = "text/html"
        env.response.status_code = 400
        next "Missing or invalid unit name."
      end

      unit_state = SystemStatus.unit_states.find do |unit|
        unit.unit == name || unit.unit == "#{name}.service"
      end
      unless unit_state
        env.response.content_type = "text/html"
        env.response.status_code = 404
        next "Unit '#{HTML.escape(name)}' not found."
      end

      # The --units whitelist scopes explanations too, matching the
      # action route's behavior.
      unless Grafito.unit_allowed?(unit_state.unit)
        env.response.content_type = "text/html"
        env.response.status_code = 403
        next "Unit '#{HTML.escape(name)}' is outside this deployment's --units whitelist."
      end

      flags = Grafito.enable_actions? ? SystemStatus.unit_flags_map[name]? : nil
      recent = Journalctl.query(since: "-6h", unit: unit_state.unit, lines: 100) || [] of Journalctl::LogEntry
      errors = recent.count { |entry| entry.priority.to_i? ? entry.priority.to_i <= 3 : false }

      report = String.build do |str|
        str << "Unit: #{unit_state.unit}\n"
        str << "Description: #{unit_state.description}\n"
        str << "Load state: #{unit_state.load_state}\n"
        str << "Active state: #{unit_state.active_state} (#{unit_state.sub_state})\n"
        str << "Unit file state: #{flags.try(&.file_state) || "unknown"}\n"
        str << "Can start: #{flags && !flags.can_start ? "no" : "yes"}\n"
        str << "Errors (priority <= 3) in recent entries: #{errors}\n"
        status_output = SystemStatus.unit_status_output(unit_state.unit)
        if status_output
          str << "\nsystemctl status output:\n"
          str << status_output
          str << "\n" unless status_output.ends_with?("\n")
        else
          str << "\nsystemctl status output: unavailable\n"
        end
        str << "\nRecent journal entries (last 6h, up to #{recent.size} lines):\n"
        recent.each do |entry|
          str << "[#{entry.formatted_timestamp_with_timezone}] [#{entry.formatted_priority}] #{entry.message}\n"
        end
      end

      begin
        request = Grafito::AI::Request.for_unit_diagnosis(report)
        response = provider.complete(request)
        Log.info { "AI unit explanation generated for #{unit_state.unit} (#{response.content.size} chars)" }
        env.response.content_type = "text/html"
        Dashboard.unit_ai_fragment(response.content)
      rescue ex : Exception
        Log.error(exception: ex) { "AI unit explanation failed for #{unit_state.unit}" }
        env.response.content_type = "text/html"
        # A 200 keeps htmx swapping so the user sees the failure inline.
        Dashboard.unit_ai_fragment("AI request failed: #{ex.message}")
      end
    end

    # ## The unit action endpoint
    #
    # `POST /unit/<name>/<start|stop|restart|enable|disable>` runs
    # systemctl for the named unit. Gated by `--enable-actions`; what an
    # action is actually allowed to do is decided by systemd/polkit for
    # the user Grafito runs as — failures are surfaced verbatim.
    # Returns the refreshed dashboard fragment (or, for `from=panel`
    # requests, the refreshed service panel) so the htmx button updates
    # the view.
    post route_path("unit/:name/:action") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless Grafito.dashboard_enabled? && Grafito.actions_available?
        env.response.status_code = 403
        next "Unit actions are disabled. Start grafito with --enable-actions and authentication configured (GRAFITO_AUTH_USER/GRAFITO_AUTH_PASS) to allow them."
      end

      unit_name = env.params.url["name"]
      action = env.params.url["action"]

      # Lifecycle and enablement actions; the list is a whitelist too,
      # so anything else is rejected before reaching systemctl.
      unless {"start", "stop", "restart", "enable", "disable"}.includes?(action)
        env.response.status_code = 400
        next "Invalid action '#{HTML.escape(action)}'."
      end

      # Unit names come URL-decoded from the router and go straight into
      # a Process.run argument array (no shell), but reject anything that
      # could be mistaken for a flag.
      if unit_name.empty? || unit_name.starts_with?('-') || !unit_name.matches?(/^[\w.@-]+$/)
        env.response.status_code = 400
        next "Invalid unit name."
      end

      known_units = SystemStatus.unit_states.map(&.unit)
      full_unit = known_units.includes?(unit_name) ? unit_name : "#{unit_name}.service"
      unless known_units.includes?(full_unit)
        env.response.status_code = 404
        next "Unit '#{HTML.escape(unit_name)}' not found."
      end

      # The --units whitelist scopes the whole operator UI to a subset
      # of units; actions must honor it, not just the log queries.
      unless Grafito.unit_allowed?(full_unit)
        env.response.status_code = 403
        next "Unit '#{HTML.escape(unit_name)}' is outside this deployment's --units whitelist."
      end

      {% if flag?(:demo_mode) %}
        # Demo build: simulate the systemctl action against the fake
        # unit table; nothing runs on the host.
        if refreshed = SystemStatus.apply_unit_action(full_unit, action)
          Log.info { "Demo mode: systemctl #{action} #{full_unit} simulated" }
          env.response.content_type = "text/html"
          # Actions triggered from the sidebar refresh the panel instead
          # of the whole dashboard; the dashboard catches up on its next
          # poll. Same response shape as the real path below.
          if optional_query_param(env, "from") == "panel"
            next Dashboard.unit_details_fragment(
              refreshed,
              Grafito.enable_actions?,
              unit_error_count(full_unit),
              SystemStatus.unit_flags_map,
            )
          end
          next render_dashboard_fragment
        end
        env.response.status_code = 500
        next "Failed to simulate the action."
      {% else %}
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        result = Process.run(
          "systemctl",
          args: Journalctl.user_flags + [action, full_unit],
          output: stdout,
          error: stderr,
        )
        unless result.success?
          # Authorization and other failures come from systemd itself;
          # surface them instead of a generic message. Panel requests get
          # an error fragment swapped into the sidebar (htmx ignores error
          # statuses, so a success status is needed to show it).
          from_panel = optional_query_param(env, "from") == "panel"
          message = stderr.to_s.strip
          message = "systemctl #{action} #{full_unit} failed." if message.empty?
          Log.error { "systemctl #{action} #{full_unit} failed: #{message[0..200]}" }
          if from_panel
            env.response.status_code = 200
            env.response.content_type = "text/html"
            next Dashboard.action_error_fragment(action, full_unit, message)
          end
          env.response.status_code = 500
          next HTML.escape(message)
        end

        Log.info { "systemctl #{action} #{full_unit} succeeded" }
        env.response.content_type = "text/html"
        # Actions triggered from the sidebar refresh the panel instead of
        # the whole dashboard; the dashboard catches up on its next poll.
        if optional_query_param(env, "from") == "panel"
          refreshed = SystemStatus.unit_states.find { |unit| unit.unit == full_unit }
          if refreshed
            next Dashboard.unit_details_fragment(
              refreshed,
              Grafito.enable_actions?,
              unit_error_count(full_unit),
              Grafito.enable_actions? ? SystemStatus.unit_flags_map : {} of String => SystemStatus::UnitFileFlags,
            )
          end
        end
        render_dashboard_fragment
      {% end %}
    end
  end

  # ## Dashboard helpers

  # Default time window for the dashboard history chart and error count.
  # A method, not a constant: a constant is evaluated once at boot,
  # so the default window would grow with the process's uptime.
  def self.default_dashboard_since
    Time.utc - 6.hours
  end

  # Counts journal entries at priority <= 3 (error or worse) for one
  # unit since the given relative time. Bounded like the dashboard's
  # global error count.
  private def self.unit_error_count(unit_name : String, since : String = "-1h") : Int32
    return 0 unless Grafito.dashboard_enabled?
    logs = Journalctl.query(since: since, priority: "3", unit: unit_name, lines: 500)
    logs ? logs.size : 0
  end

  # Returns the dashboard HTML fragment used by both GET /dashboard and
  # the unit-action POST responses. Invalid since values fall back to
  # the default 6-hour window.
  private def self.render_dashboard_fragment(
    sort_by : String? = nil,
    sort_order : String? = nil,
    unit_filter : String? = nil,
    since_text : String? = nil,
    unit_flags : Hash(String, SystemStatus::UnitFileFlags) = {} of String => SystemStatus::UnitFileFlags,
    snapshot : SystemStatus::Snapshot? = nil,
  ) : String
    # Callers that already hold a fresh snapshot (the /dashboard poll)
    # pass it in; action responses leave it nil so the post-action
    # state is sampled fresh.
    snapshot = snapshot || SystemStatus.snapshot
    since_time = parse_since(since_text.to_s) || default_dashboard_since
    # Downsampled to a chart-friendly point count: a 7-day window is
    # ~20000 raw samples, which the SVG would serialize coordinate by
    # coordinate. Use ?max_points= on /status/history for raw data.
    history = Grafito.metrics_store.try(&.history_downsampled(since_time)) || [] of Grafito::MetricsStore::MetricPoint
    entries = dashboard_journal_entries(since_text.presence || "-6h")
    buckets = severity_buckets(entries, history)
    errors = entries.count { |entry| (entry.priority.to_i? || 7) <= 3 }
    oom_kills = recent_oom_count(since_text.presence || "-6h")
    Dashboard.render_html(
      snapshot,
      history,
      errors,
      oom_kills,
      Grafito.enable_actions?,
      sort_by,
      sort_order,
      unit_filter,
      since_text,
      unit_flags,
      buckets,
      SystemStatus.unit_resource_usage(snapshot.units.map(&.unit)),
    )
  end

  # Journal entries over the given relative time for the dashboard
  # chart: all severities, bounded to 5000 entries to keep refreshes
  # cheap; the chart is a signal, not an audit.
  # Public: other views (e.g. the process monitor) reuse the same
  # combo chart data pipeline.
  def self.dashboard_journal_entries(since : String) : Array(Journalctl::LogEntry)
    return [] of Journalctl::LogEntry unless Grafito.dashboard_enabled?
    Journalctl.query(since: since, lines: 5000) || [] of Journalctl::LogEntry
  end

  # Buckets journal entries by severity over the exact time span
  # covered by the metrics history, so the stacked severity bars line
  # up pixel-for-pixel with the load/memory lines in the combined
  # chart.
  # Public: other views (e.g. the process monitor) reuse the same
  # combo chart data pipeline.
  def self.severity_buckets(
    logs : Array(Journalctl::LogEntry),
    history : Array(Grafito::MetricsStore::MetricPoint),
  ) : Array(Timeline::TimelinePoint)
    return [] of Timeline::TimelinePoint if history.size < 2
    oldest = history.first.ts
    span_sec = [(history.last.ts - oldest).total_seconds, 1.0].max
    bucket_count = 60
    bucket_sec = span_sec / bucket_count
    buckets = Array.new(bucket_count) do |index|
      start_time = oldest + Time::Span.new(seconds: (index * bucket_sec).to_i)
      {start_time: start_time, count: 0, err: 0, warn: 0, info: 0}
    end
    logs.each do |entry|
      offset = (entry.timestamp - oldest).total_seconds
      next if offset < 0
      index = (offset / bucket_sec).to_i
      next if index >= bucket_count
      bucket = buckets[index]
      count = bucket[:count] + 1
      case entry.priority.to_i? || 7
      when 0..3
        buckets[index] = {start_time: bucket[:start_time], count: count, err: bucket[:err] + 1, warn: bucket[:warn], info: bucket[:info]}
      when 4
        buckets[index] = {start_time: bucket[:start_time], count: count, err: bucket[:err], warn: bucket[:warn] + 1, info: bucket[:info]}
      else
        buckets[index] = {start_time: bucket[:start_time], count: count, err: bucket[:err], warn: bucket[:warn], info: bucket[:info] + 1}
      end
    end
    buckets
  end

  # Counts journal entries at priority <= 3 (error or worse) since the
  # given relative time. Bounded to 500 lines to keep dashboard refreshes
  # cheap; the count is a signal, not an audit.
  private def self.recent_error_count(since : String) : Int32
    return 0 unless Grafito.dashboard_enabled?
    logs = Journalctl.query(since: since, priority: "3", lines: 500)
    logs ? logs.size : 0
  end

  # Journal message patterns the kernel emits on an OOM kill ("Out of
  # memory: Killed process …" and the newer "oom-kill" accounting
  # lines). Matched with journalctl's grep (-g).
  OOM_GREP = "Out of memory|oom-kill|oom_kill"

  # Counts kernel OOM-kill events since the given relative time, for
  # the dashboard card. Bounded like the error count.
  private def self.recent_oom_count(since : String) : Int32
    return 0 unless Grafito.dashboard_enabled?
    logs = Journalctl.query(since: since, query: OOM_GREP, lines: 500)
    logs ? logs.size : 0
  end

  # Serializes metric points as CSV: one header row, then one row per
  # sample. Optional fields render as empty cells on pre-network /
  # swapless history; the per-interface breakdown becomes a compact
  # `iface:rx/tx;…` column so exports stay single-row-per-sample.
  def self.metrics_csv(points : Array(Grafito::MetricsStore::MetricPoint)) : String
    CSV.build do |csv|
      csv.row "ts", "load1", "mem_used_pct", "disk_used_pct", "swap_used_pct",
        "units_total", "units_failed", "net_rx_bps", "net_tx_bps", "net"
      points.each do |point|
        net = point.net.try(&.map { |name, rate| "#{name}:#{rate.rx_bps.round(1)}/#{rate.tx_bps.round(1)}" }.join(";"))
        csv.row point.ts.to_s("%FT%T%:z"), point.load1, point.mem_used_pct, point.disk_used_pct,
          point.swap_used_pct, point.units_total, point.units_failed,
          point.net_rx_bps, point.net_tx_bps, net
      end
    end
  end

  # Parses the same relative time vocabulary the logs endpoint uses
  # (-15m, -1h, -1d, -1M, -1y) into a Time.
  # Public: other views (e.g. the process monitor) reuse the same
  # combo chart data pipeline.
  def self.parse_since(since_text : String) : Time?
    match = since_text.strip.match(/^-?(\d+)([mhdMy])$/)
    return unless match

    amount = match[1].to_i
    span = case match[2]
           when "m" then Time::Span.new(minutes: amount)
           when "h" then Time::Span.new(hours: amount)
           when "d" then Time::Span.new(days: amount)
           when "M" then Time::Span.new(days: amount * 30)
           else          Time::Span.new(days: amount * 365) # "y"
           end
    Time.utc - span
  end
end
