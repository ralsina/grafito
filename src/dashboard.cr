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

require "./system_status"
require "./metrics_store"

module Dashboard
  extend self

  Log = ::Log.for(self)

  # Renders the dashboard fragment. `history` may be empty (e.g. the
  # sampler just started); `errors_last_hour` comes from the journal.
  # `sort_by`/`sort_order` control the unit table ordering.
  def render_html(
    snapshot : SystemStatus::Snapshot,
    history : Array(Grafito::MetricsStore::MetricPoint),
    errors_last_hour : Int32,
    enable_actions : Bool = false,
    sort_by : String? = nil,
    sort_order : String? = nil,
  ) : String
    # Units arrive sorted by name from SystemStatus; apply the requested
    # column sort on top (defaulting to name, ascending).
    sort_key = normalize_sort_key(sort_by)
    ascending = normalize_sort_order(sort_order) == "asc"
    units = sort_units(snapshot.units, sort_key, ascending)

    HTML.build do
      div(class: "dashboard-grid") do
        html card("Uptime", format_uptime(snapshot.uptime_sec))
        html card("Load (1m)", snapshot.load1.round(2).to_s)
        html card("Memory", "#{snapshot.mem_used_pct.round(1)}%", warn: snapshot.mem_used_pct >= 90.0)
        html card("Disk", "#{snapshot.disk_used_pct.round(1)}%", warn: snapshot.disk_used_pct >= 90.0)
        html card("Failed units", snapshot.units_failed.to_s, warn: snapshot.units_failed > 0)
        html card("Errors (1h)", errors_last_hour.to_s, warn: errors_last_hour > 20)
      end

      if history.size >= 2
        div(style: "margin: 1em 0;") do
          html generate_svg_history(history)
        end
      end

      tag("h4") do
        text "Services (#{snapshot.units_total})"
      end

      table(class: "striped dashboard-units") do
        thead do
          tr do
            html sortable_header("Unit", "unit", sort_key, ascending)
            html sortable_header("State", "state", sort_key, ascending)
            html sortable_header("Sub", "sub", sort_key, ascending)
            html sortable_header("Description", "description", sort_key, ascending)
            if enable_actions
              th { text "Actions" }
            end
          end
        end
        tbody do
          if units.empty?
            td(colspan: enable_actions ? "5" : "4", style: "text-align: center; padding: 1em;") do
              text "No systemd units found."
            end
          else
            units.each do |unit_state|
              html unit_row(unit_state, enable_actions)
            end
          end
        end
      end
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
  private def card(label : String, value : String, warn : Bool = false) : String
    HTML.build do
      div(class: "stat") do
        span(class: "stat-label") { text label }
        span(class: warn ? "stat-value stat-error" : "stat-value") do
          text value
        end
      end
    end
  end

  private def unit_row(unit_state : SystemStatus::UnitState, enable_actions : Bool) : String
    HTML.build do
      tr(class: unit_state.failed? ? "dashboard-unit-failed" : "") do
        td do
          js_arg_unit_name = unit_state.unit.to_json
          a(href: "#", onclick: "return setUnitFilterAndTrigger(#{js_arg_unit_name});") do
            text HTML.escape(unit_state.unit)
          end
        end
        td do
          span_class = case unit_state.active_state
                       when "active"                  then "tag"
                       when "failed"                  then "tag tag-error"
                       when "activating", "reloading" then "tag tag-warn"
                       else                                "tag tag-muted"
                       end
          span(class: span_class) { text HTML.escape(unit_state.active_state) }
        end
        td do
          text HTML.escape(unit_state.sub_state)
        end
        td do
          text HTML.escape(unit_state.description)
        end
        if enable_actions
          html action_cell(unit_state.unit)
        end
      end
    end
  end

  # Start/stop/restart buttons. htmx's hx-confirm attribute supplies the
  # confirmation dialog; the POST swaps the refreshed dashboard in.
  private def action_cell(unit_name : String) : String
    HTML.build do
      td(class: "dashboard-action-cell") do
        {"restart" => "restart_alt", "start" => "play_arrow", "stop" => "stop"}.each do |action, icon|
          confirm_text = "#{action[0].upcase}#{action[1..]} unit #{unit_name}?"
          attributes = {
            "class"        => "round-button",
            "title"        => "#{action[0].upcase}#{action[1..]} #{unit_name}",
            "hx-post"      => build_action_url(unit_name, action),
            "hx-target"    => "#dashboard-view",
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
    end
  end

  private def build_action_url(unit_name : String, action : String) : String
    base = Grafito.base_path == "/" ? "" : Grafito.base_path
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

  # Renders memory and disk usage over time as a small SVG line chart.
  # Both series share the same 0-100% scale, which makes them directly
  # comparable without any y-axis beyond 0/50/100 marks.
  def generate_svg_history(points : Array(Grafito::MetricsStore::MetricPoint)) : String
    svg = IO::Memory.new
    width = 800.0
    height = 120.0
    oldest = points.first.ts
    span_sec = [(points.last.ts - oldest).total_seconds, 1.0].max

    svg << %(<svg width="100%" height="#{height.to_i}" viewBox="0 0 #{width.to_i} #{height.to_i}" )
    svg << %(preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg" role="img" class="dashboard-history-svg">)
    svg << %(  <polyline fill="none" stroke="var(--info, steelblue)" stroke-width="2" points="#{polyline_points(points, oldest, span_sec, width, height, &.mem_used_pct)}" />)
    svg << %(  <polyline fill="none" stroke="var(--err, darkorange)" stroke-width="2" points="#{polyline_points(points, oldest, span_sec, width, height, &.disk_used_pct)}" />)
    svg << %(  <text x="8" y="#{(height - 8).to_i}" class="tl-label">#{points.first.ts.to_s("%m-%d %H:%M")}</text>)
    svg << %(  <text x="#{(width - 8).to_i}" y="#{(height - 8).to_i}" text-anchor="end" class="tl-label">#{points.last.ts.to_s("%m-%d %H:%M")}</text>)
    svg << %(</svg>)
    svg.to_s
  end

  # Builds the x/y point list for one series: x spans the time range,
  # y is the percentage value mapped to the SVG height (inverted).
  private def polyline_points(
    points : Array(Grafito::MetricsStore::MetricPoint),
    oldest : Time,
    span_sec : Float64,
    width : Float64,
    height : Float64,
    &value : Grafito::MetricsStore::MetricPoint -> Float64
  ) : String
    padding = 8.0
    usable = height - 2 * padding
    points.map do |point|
      x = padding + ((point.ts - oldest).total_seconds / span_sec) * (width - 2 * padding)
      y = padding + (1.0 - value.call(point).clamp(0.0, 100.0) / 100.0) * usable
      "#{x.round(1)},#{y.round(1)}"
    end.join(" ")
  end
end
