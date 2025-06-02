require "kemal" # For HTTP::Server::Context and HTML
require "json"
require "./journalctl"
require "./timeline"
require "html_builder"

# Regex is part of Crystal core, no explicit require needed for it.

module Grafito
  # Helper to get an optional query parameter, treating empty strings as nil.
  private def optional_query_param(env : HTTP::Server::Context, key : String) : String?
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

  # Generates an HTML representation of log entries.
  # ameba:disable Metrics/CyclomaticComplexity
  private def html_log_output(
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
    show_priority : Bool = true,
    show_message : Bool = true,
  ) : String
    HTML.build do
      if chart
        # Generate and add the timeline SVG only if there are logs
        if !logs.empty?
          timeline_data = Timeline.generate_frequency_timeline(logs)
          svg_timeline_html = Timeline.generate_svg_timeline(timeline_data)
          div(style: "margin-bottom: 1em;") do
            html svg_timeline_html
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
      styled_count_span = %Q(<span style="font-style: italic; font-size: 0.9em; color: var(--pico-muted-color); margin-left: 0.5em;">(#{count_message_inner_text})</span>)
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
                "style"        => "cursor: pointer; vertical-align: middle;",
                "hx-get"       => "/logs",
                "hx-vals"      => header[:hx_vals],
                "hx-include"   => "#search-box, #unit-filter, #tag-filter, #priority-filter, #time-range-filter, #live-view",
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
              if highlight_cursor && entry_cursor == highlight_cursor
                row_classes << "highlighted-row"
              end
              tr(class: row_classes.join(" ")) do
                if show_timestamp
                  td(style: "white-space: nowrap; min-width: 14ch;") do
                    # Using a more compact timestamp format: MM-DD HH:MM:SS
                    text entry.timestamp.to_s("%m-%d %H:%M:%S")
                  end
                end
                if show_hostname
                  td do
                    text HTML.escape(entry.hostname)
                  end
                end
                if show_unit
                  td do
                    # Make the unit name clickable to set the filter
                    display_unit_name = HTML.escape(entry.unit)
                    # JSON.generate creates a valid JavaScript string literal, e.g., "\"my-unit\""
                    js_arg_unit_name = entry.unit.to_json
                    a(href: "#", onclick: "return setUnitFilterAndTrigger(#{js_arg_unit_name});") do
                      text display_unit_name
                    end
                  end
                end
                if show_priority
                  td do
                    text HTML.escape(entry.formatted_priority)
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
                  # Details button
                  td(class: "hover-action-cell", style: "width: 1%; white-space: nowrap; text-align: center; padding: 0.1em;") do
                    button({
                      "class"                     => "round-button",
                      "title"                     => "View full details for this log entry",
                      "hx-get"                    => "details?#{URI::Params.encode({"cursor" => entry_cursor})}",
                      "hx-target"                 => "#details-dialog-content", # Target the content area within the modal
                      "hx-swap"                   => "innerHTML",
                      "hx-on:htmx:before-request" => "document.getElementById('details-dialog-content').innerHTML = document.getElementById('details-dialog-loading-spinner-template').innerHTML;",
                      "hx-on:htmx:after-request"  => "if(event.detail.successful) { document.getElementById('details-dialog').showModal(); } else { document.getElementById('details-dialog-content').innerHTML = '<p class=\\'error\\'>Failed to load details. Status: ' + event.detail.xhr.status + ' ' + event.detail.xhr.statusText + '</p>'; document.getElementById('details-dialog').showModal(); }",
                    }) do
                      span(class: "material-icons", style: "vertical-align: middle;") do
                        text "search"
                      end
                    end
                  end
                  # Context button
                  td(class: "hover-action-cell", style: "width: 1%; white-space: nowrap; text-align: center; padding: 0.1em;") do
                    button({
                      "class"                     => "round-button",
                      "title"                     => "View context for this log entry (e.g., 5 before & 5 after)",
                      "hx-get"                    => "context?#{URI::Params.encode({"cursor" => entry_cursor})}",
                      "hx-target"                 => "#details-dialog-content", # Target the content area within the modal
                      "hx-swap"                   => "innerHTML",
                      "hx-on:htmx:before-request" => "document.getElementById('details-dialog-content').innerHTML = document.getElementById('details-dialog-loading-spinner-template').innerHTML;",
                      "hx-on:htmx:after-request"  => "if(event.detail.successful) { document.getElementById('details-dialog').showModal(); } else { document.getElementById('details-dialog-content').innerHTML = '<p class=\\'error\\'>Failed to load details. Status: ' + event.detail.xhr.status + ' ' + event.detail.xhr.statusText + '</p>'; document.getElementById('details-dialog').showModal(); }",
                    }) do
                      span(class: "material-icons", style: "vertical-align: middle;") do
                        text "history"
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
  end
end
