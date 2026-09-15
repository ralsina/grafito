require "kemal"
require "compress/gzip" # For HTTP::Server::Context and HTML and Kemal::Handler
require "json"
require "./journalctl"
require "./timeline"
require "html_builder"

# Regex is part of Crystal core, no explicit require needed for it.

module Grafito
  # Middleware to shut down the server if it's idle for a given amount of time
  private class IdleShutdownHandler < Kemal::Handler
    @timeout_sec : Int32
    @channel : Channel(Nil)
    @logger : ::Log

    def initialize(*, timeout_sec : Int32, logger : ::Log)
      @timeout_sec = timeout_sec
      @logger = logger
      @channel = Channel(Nil).new
      spawn(name: "IdleShutdownHandler(#{timeout_sec}s)") do
        # Loop forever, exiting when timeout_sec passes without a new request
        loop do
          select
          when @channel.receive
          when timeout(timeout_sec.seconds)
            @logger.info { "Shutting down because idle timeout was reached" }
            exit 0
          end
        end
      end
    end

    def call(context)
      # On a request, reset the idle timer
      spawn do
        @channel.send(nil)
      end
      call_next(context)
    end
  end

  # Sets cache headers appropriate for each asset type: HTML documents
  # must always revalidate (they link the other assets), while CSS/JS may
  # be cached briefly by browsers and CDNs. Without this, deployments
  # under caching proxies (e.g. Cloudflare) serve stale frontends for as
  # long as the default TTL.
  private class CacheHeadersHandler < Kemal::Handler
    def call(context)
      call_next(context)
      content_type = context.response.headers["Content-Type"]?
      if content_type
        if content_type.starts_with?("text/html")
          context.response.headers["Cache-Control"] = "no-cache"
        elsif content_type.starts_with?("text/css") ||
              content_type.starts_with?("application/javascript") ||
              content_type.starts_with?("text/javascript")
          context.response.headers["Cache-Control"] = "public, max-age=300"
        end
      end
    end
  end

  # Compresses text responses with gzip when the client accepts it. The
  # baked asset handler and the log endpoints serve large uncompressed
  # HTML/CSS/JS payloads, so this saves 70-90% of the transfer size.
  private class GzipHandler < Kemal::Handler
    COMPRESSIBLE = /^text\/|^application\/(json|javascript)/

    def call(context)
      accepts = context.request.headers["Accept-Encoding"]?
      if accepts.try(&.includes?("gzip"))
        original_output = context.response.output
        buffer = IO::Memory.new
        context.response.output = buffer
        call_next(context)
        content_type = context.response.headers["Content-Type"]?
        if content_type.try(&.matches?(COMPRESSIBLE)) && buffer.bytesize > 512 &&
           !context.response.headers.has_key?("Content-Encoding")
          context.response.output = original_output
          context.response.headers["Content-Encoding"] = "gzip"
          context.response.headers.delete("Content-Length")
          buffer.rewind
          Compress::Gzip::Writer.open(original_output) { |gz| IO.copy(buffer, gz) }
        else
          context.response.output = original_output
          context.response.print buffer.to_s
        end
      else
        call_next(context)
      end
    end
  end

  # Helper to build URLs with proper base path handling
  private def build_url(path : String) : String
    if Grafito.base_path == "/"
      "/#{path}"
    else
      "#{Grafito.base_path}/#{path}"
    end
  end

  # Helper to get an optional query parameter, treating empty strings as nil.
  # Blocks state-changing cross-site POSTs (CSRF): browsers attach
  # cached basic-auth credentials to any request to this origin, so a
  # malicious page could ride an authenticated session to run
  # privileged actions.
  #
  # Modern browsers send Sec-Fetch-Site on every request: same-origin
  # and none are allowed, cross-site is rejected. Older browsers are
  # checked via Origin/Referer against the Host header when present.
  # Non-browser clients (curl, monitoring) send none of these headers
  # and are allowed — basic auth still applies to them.
  #
  # Returns true when the request must be rejected; the caller halts.
  # ameba:disable Metrics/CyclomaticComplexity
  def reject_cross_site_post?(env : HTTP::Server::Context) : Bool
    return false unless env.request.method == "POST"

    host = env.request.headers["Host"]?
    headers = env.request.headers

    if sec_fetch = headers["Sec-Fetch-Site"]?
      unless {"same-origin", "none"}.includes?(sec_fetch.downcase)
        Log.warn { "Rejected cross-site POST to #{env.request.path} (Sec-Fetch-Site: #{sec_fetch}, possible CSRF)" }
        return true
      end
      return false
    end

    if origin = headers["Origin"]?
      if host && URI.parse(origin).authority != host
        Log.warn { "Rejected cross-site POST to #{env.request.path} (Origin mismatch, possible CSRF)" }
        return true
      end
      return false
    end

    if referer = headers["Referer"]?
      if host && (ref_authority = URI.parse(referer).authority) && ref_authority != host
        Log.warn { "Rejected cross-site POST to #{env.request.path} (Referer mismatch, possible CSRF)" }
        return true
      end
    end

    false
  end

  # Public: view modules delegate their own route helpers to these.
  def optional_query_param(env : HTTP::Server::Context, key : String) : String?
    param = env.params.query[key]?
    param.nil? || param.strip.empty? ? nil : param
  end

  # Generates attributes for sortable table headers.
  # Returns a NamedTuple with text, hx_vals (JSON string), and key_name.
  private def _generate_header_attributes(
    column_key_name : String,
    display_text : String,
    current_sort_by : String?,
    current_sort_order : String?,
  ) : NamedTuple(text: String, hx_vals: String, key_name: String)
    sort_indicator = ""
    next_sort_order_for_click = "asc" # Default next sort is ascending

    if current_sort_by == column_key_name # This column is currently being sorted
      case current_sort_order
      when "asc" # Up arrow for ascending
        sort_indicator = %q( <span class="material-icons" aria-hidden="true" style="font-size: inherit; vertical-align: middle;">arrow_upward</span>)
        next_sort_order_for_click = "desc" # Next click will be descending
      when "desc"                          # Down arrow for descending
        sort_indicator = %q( <span class="material-icons" aria-hidden="true" style="font-size: inherit; vertical-align: middle;">arrow_downward</span>)
        next_sort_order_for_click = "asc" # Next click will be ascending
      else                                # current_sort_order is nil or unexpected, default to ascending for next click
        next_sort_order_for_click = "asc"
      end
    elsif current_sort_by.nil? && column_key_name == "timestamp"
      # No specific sort requested by user, and this is the timestamp column.
      # Default sort is by timestamp, descending.
      sort_indicator = %q( <span class="material-icons" aria-hidden="true" style="font-size: inherit; vertical-align: middle;">arrow_downward</span>)
      # If user clicks on timestamp, the next sort should be ascending.
      next_sort_order_for_click = "asc"
    end

    vals_json = %({"sort_by": "#{column_key_name}", "sort_order": "#{next_sort_order_for_click}"})

    {
      text:     display_text + sort_indicator,
      hx_vals:  vals_json,
      key_name: column_key_name,
    }
  end

  # Generates a plain text representation of log entries.
  def _generate_text_log_output(logs : Array(Journalctl::LogEntry)) : String
    String.build do |str|
      if logs.empty?
        str << "No log entries found.\n"
      else
        logs.each do |entry|
          str << entry.formatted_timestamp
          str << " [#{entry.hostname}]" # Add hostname to text output
          str << " [#{entry.unit}]"     # Always include unit in text output
          str << " (#{entry.formatted_priority}) "
          str << entry.message << '\n'
        end
      end
    end
  end

  # Generates a single hover-action button cell for a log entry row.
  # The htmx buttons share almost all attributes; only the icon, tooltip and
  # URL differ. The AI button instead triggers a JavaScript function and takes
  # an onclick handler. `js_arg` is interpolated verbatim and must already be
  # a valid JavaScript literal (use `.to_json` for strings). `tab` selects
  # which sidebar pane the response lands in.
  private def _hover_action_button_cell(
    title : String,
    icon : String,
    tab : String,
    url : String? = nil,
    onclick : String? = nil,
  ) : String
    attributes = {
      "class" => "round-button",
      "title" => title,
    }
    if onclick
      attributes["onclick"] = onclick
    else
      attributes = attributes.merge({
        "hx-get"                    => url || "",
        "hx-target"                 => "#panel-#{tab}-content",
        "hx-swap"                   => "innerHTML",
        "hx-on:htmx:before-request" => "panelSpinner('#panel-#{tab}-content')",
        "hx-on:htmx:after-request"  => "if(event.detail.successful){showLogPanel('#{tab}')}else{panelError('#panel-#{tab}-content',event.detail.xhr.status);showLogPanel('#{tab}')}",
      })
    end
    HTML.build do
      td(class: "hover-action-cell", style: "width: 1%; white-space: nowrap; text-align: center; padding: 0.1em;") do
        button(attributes) do
          span(class: "material-icons", style: "vertical-align: middle;") do
            text icon
          end
        end
      end
    end
  end

  # Generates an HTML representation of log entries.
  # ameba:disable Metrics/CyclomaticComplexity
  def html_log_output(
    logs : Array(Journalctl::LogEntry),
    current_sort_by : String?,
    current_sort_order : String?,
    search_query : String?,
    chart : Bool = true,
    highlight_cursor : String? = nil,
    # Column visibility flags - determined by the route handler from query parameters
    show_timestamp : Bool = true,
    show_hostname : Bool = true,
    show_unit : Bool = true,
    show_tag : Bool = true,
    show_priority : Bool = true,
    show_message : Bool = true,
  ) : String
    HTML.build do
      if chart
        # Generate and add the timeline SVG only if there are logs
        if !logs.empty?
          # Align chart buckets to the timezone the table displays.
          timeline_location = logs.first.convert_to_timezone(logs.first.timestamp).location
          timeline_data = Timeline.generate_frequency_timeline(logs, location: timeline_location)
          # Use the combined chart (severity bars + memory/disk lines,
          # same as the dashboard) when the metrics sampler is running;
          # fall back to the plain severity timeline otherwise.
          oldest_log = logs.min_of(&.timestamp)
          metric_points = Grafito.metrics_store.try(&.history(oldest_log - 1.minute)) ||
                          [] of Grafito::MetricsStore::MetricPoint
          div(style: "margin-bottom: 1em;") do
            if metric_points.empty?
              html Timeline.generate_svg_timeline(timeline_data)
            else
              html Timeline.combined_legend
              html Timeline.generate_combined_svg(metric_points, timeline_data)
            end
          end
        end
      end

      # Display results count
      count_message_inner_text = if logs.size == 5000
                                   "showing first 5000 entries"
                                 elsif logs.size == 1
                                   "showing 1 entry"
                                 else
                                   "showing #{logs.size} entries" # Handles 0 and other counts
                                 end

      # Prepare the styled count message for the header
      styled_count_span = %Q(<span class="results-count" style="font-style: italic; font-size: 0.9em; color: var(--pico-muted-color); margin-left: 0.5em;">(#{count_message_inner_text})</span>)
      message_header_text = "Message #{styled_count_span}"

      headers_to_display = [] of NamedTuple(text: String, hx_vals: String, key_name: String)

      if show_timestamp
        headers_to_display << _generate_header_attributes("timestamp", "Timestamp", current_sort_by, current_sort_order)
      end
      if show_hostname
        headers_to_display << _generate_header_attributes("hostname", "Hostname", current_sort_by, current_sort_order)
      end
      if show_unit
        headers_to_display << _generate_header_attributes("unit", "Unit", current_sort_by, current_sort_order)
      end
      if show_tag
        headers_to_display << _generate_header_attributes("tag", "Tags", current_sort_by, current_sort_order)
      end
      if show_priority
        headers_to_display << _generate_header_attributes("priority", "Priority", current_sort_by, current_sort_order)
      end
      if show_message
        headers_to_display << _generate_header_attributes("message", message_header_text, current_sort_by, current_sort_order)
      end

      table(class: "striped") do
        thead do
          tr do
            headers_to_display.each do |header|
              # All remaining headers are sortable and will use this block
              th({
                "style"   => "cursor: pointer; vertical-align: middle;",
                "hx-get"  => build_url("logs"),
                "hx-vals" => header[:hx_vals],
                # Include every .log-filter so column-visibility toggles and
                # the hostname filter survive sort requests (a stale hardcoded
                # whitelist used to blank the table here).
                "hx-include"   => ".log-filter",
                "hx-target"    => "#results",
                "hx-indicator" => "#loading-spinner",
              }) do
                html header[:text]
              end
            end
          end
        end
        tbody do
          if logs.empty?
            tr do
              td(colspan: Math.max(1, headers_to_display.size).to_s, style: "text-align: center; padding: 1em;") do
                text "No log entries found."
              end
            end
          else
            logs.each do |entry|
              row_classes = ["log-row-hover-actions", "priority-#{entry.priority.to_i}"]
              entry_cursor = entry.data["__CURSOR"]?
              is_target = !highlight_cursor.nil? && entry_cursor == highlight_cursor
              if is_target
                row_classes << "highlighted-row"
                row_classes << "context-target"
              end
              # The cursor rides on the row so a plain click can open the
              # detail tab in the sidebar.
              row_attributes = {"class" => row_classes.join(" ")}
              row_attributes["data-cursor"] = entry_cursor if entry_cursor
              row_attributes["data-epoch"] = entry.timestamp.to_unix.to_s
              tr(row_attributes) do
                if show_timestamp
                  td(class: "log-timestamp-cell", style: "white-space: nowrap; min-width: 14ch;") do
                    if is_target
                      span(class: "context-target-badge") do
                        text "this entry"
                      end
                      text " "
                    end
                    # Using timezone-aware timestamp format: MM-DD HH:MM:SS
                    text entry.formatted_timestamp_with_timezone("%m-%d %H:%M:%S")
                  end
                end
                if show_hostname
                  td(class: "log-hostname-cell") do
                    # Make the hostname clickable to set the filter
                    display_hostname = HTML.escape(entry.hostname)
                    js_arg_hostname = entry.hostname.to_json # Ensures proper JS string escaping
                    a(href: "#", onclick: "return setHostnameFilterAndTrigger(#{js_arg_hostname});") do
                      text display_hostname
                    end
                  end
                end
                if show_unit
                  td(class: "log-unit-cell") do
                    # Make the unit name clickable to set the filter
                    display_unit_name = HTML.escape(entry.unit)
                    # JSON.generate creates a valid JavaScript string literal, e.g., "\"my-unit\""
                    js_arg_unit_name = entry.unit.to_json
                    a(href: "#", onclick: "return setUnitFilterAndTrigger(#{js_arg_unit_name});") do
                      text display_unit_name
                    end
                  end
                end
                if show_tag
                  td(class: "log-tag-cell") do
                    # Make the tag clickable to set the filter, like the
                    # unit and hostname cells.
                    if !entry.tag.strip.empty?
                      display_tag = HTML.escape(entry.tag)
                      js_arg_tag = entry.tag.to_json
                      a(href: "#", onclick: "return setTagFilterAndTrigger(#{js_arg_tag});") do
                        text display_tag
                      end
                    end
                  end
                end
                if show_priority
                  td(class: "log-priority-cell") do
                    span(class: "tag") do
                      text HTML.escape(entry.formatted_priority)
                    end
                  end
                end
                if show_message
                  escaped_message = HTML.escape(entry.message)
                  highlighted_message = if search_query && !search_query.strip.empty?
                                          pattern = Regex.escape(search_query)
                                          escaped_message.gsub(/#{pattern}/i, "<mark>\\0</mark>")
                                        else
                                          escaped_message
                                        end
                  td(class: "log-message-cell") do
                    html highlighted_message
                  end
                end

                if entry_cursor
                  cursor_param = URI::Params.encode({"cursor" => entry_cursor})
                  # Details button
                  html _hover_action_button_cell(
                    title: "View full details for this log entry",
                    icon: "search",
                    tab: "detail",
                    url: "#{build_url("details")}?#{cursor_param}",
                  )
                  # Context button
                  html _hover_action_button_cell(
                    title: "View context for this log entry (e.g., 5 before & 5 after)",
                    icon: "history",
                    tab: "context",
                    url: "#{build_url("context")}?#{cursor_param}",
                  )
                  # Copy-entry button: copies the entry as a journalctl-style
                  # line (timestamp hostname unit[pid]: message).
                  copied_entry_text = String.build do |str|
                    str << entry.formatted_timestamp_with_timezone("%Y-%m-%d %H:%M:%S")
                    str << " " << entry.hostname
                    str << " " << entry.unit
                    if pid = entry.data["_PID"]?
                      str << "[" << pid << "]"
                    end
                    str << ": " << entry.message
                  end
                  html _hover_action_button_cell(
                    title: "Copy this log entry to the clipboard",
                    icon: "content_copy",
                    tab: "copy",
                    onclick: "copyLogEntry(#{copied_entry_text.to_json}, this)",
                  )
                  # AI Explanation button (only shown if AI is enabled)
                  if Grafito.ai_enabled?
                    html _hover_action_button_cell(
                      title: "Ask AI to explain this log entry",
                      icon: "psychology",
                      tab: "ai",
                      onclick: "askAIExplanation(#{entry_cursor.to_json})",
                    )
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
