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

    if current_sort_by == column_key_name
      case current_sort_order
      when "asc"
        sort_indicator = " <span aria-hidden=\"true\">▲</span>" # Up arrow for ascending
        next_sort_order_for_click = "desc"                      # Next click will be descending
      when "desc"
        sort_indicator = " <span aria-hidden=\"true\">▼</span>" # Down arrow for descending
        next_sort_order_for_click = "asc"                       # Next click will be ascending
      else                                                      # current_sort_order is nil or something else, treat as unsorted for this column
        next_sort_order_for_click = "asc"
      end
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
          str << " [#{entry.unit}]" # Always include unit in text output
          str << " (#{entry.formatted_priority}) "
          str << entry.message << '\n'
        end
      end
    end
  end

  # Generates an HTML representation of log entries.
  private def html_log_output(
    logs : Array(Journalctl::LogEntry),
    current_sort_by : String?,
    current_sort_order : String?,
    search_query : String?,
    chart : Bool = true,
  ) : String
    HTML.build do
      if chart
        # Generate and add the timeline SVG
        timeline_data = Timeline.generate_frequency_timeline(logs)
        svg_timeline_html = Timeline.generate_svg_timeline(timeline_data)
        div(style: "margin-bottom: 1em;") do
          html svg_timeline_html
        end
      end

      # Display results count
      count_message = if logs.size == 5000
                        "Results limited to latest 5000 entries."
                      elsif logs.size == 1
                        "Showing 1 entry."
                      else
                        "Showing #{logs.size} entries." # Handles 0 and other counts
                      end

      headers_to_display = [_generate_header_attributes("timestamp", "Timestamp", current_sort_by, current_sort_order)]
      headers_to_display << _generate_header_attributes("unit", "Unit", current_sort_by, current_sort_order)
      headers_to_display << _generate_header_attributes("priority", "Priority", current_sort_by, current_sort_order)
      headers_to_display << _generate_header_attributes("message", "Message", current_sort_by, current_sort_order)
      headers_to_display << {text: "", hx_vals: "", key_name: "details"}
      headers_to_display << {text: "", hx_vals: "", key_name: "context"}

      p(class: "results-count") do # ameba:disable Lint/DebugCalls
        text count_message
      end

      table(class: "striped") do
        thead do
          tr do
            headers_to_display.each do |header|
              if header[:key_name] == "details" || header[:key_name] == "context"
                th(style: "width: 1%;") do
                  html header[:text] # Non-sortable, minimal width header
                end
              else
                th({
                  "style"        => "cursor: pointer;",
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
        end
        tbody do
          if logs.empty?
            tr do
              td(colspan: headers_to_display.size.to_s, style: "text-align: center; padding: 1em;") do
                text "No log entries found."
              end
            end
          else
            logs.each do |entry|
              tr(class: "log-row-hover-actions priority-#{entry.priority.to_i}") do
                td do
                  text entry.formatted_timestamp
                end
                td do
                  text HTML.escape(entry.unit)
                end
                td do
                  text HTML.escape(entry.formatted_priority)
                end
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
                cursor = entry.data["__CURSOR"]?
                if cursor
                  # Details button
                  td(class: "hover-action-cell", style: "width: 1%; white-space: nowrap; text-align: center; padding: 0.1em;") do
                    button({
                      "class"                     => "round-button emoji",
                      "title"                     => "View full details for this log entry",
                      "hx-get"                    => "details?#{URI::Params.encode({"cursor" => cursor})}",
                      "hx-target"                 => "#details-dialog-content",
                      "hx-swap"                   => "innerHTML",
                      "hx-on:htmx:before-request" => "document.getElementById('details-dialog-content').innerHTML = document.getElementById('details-dialog-loading-spinner-template').innerHTML;",
                      "hx-on:htmx:after-request"  => "if(event.detail.successful) { document.getElementById('details-dialog').showModal(); } else { document.getElementById('details-dialog-content').innerHTML = '<p class=\\'error\\'>Failed to load details. Status: ' + event.detail.xhr.status + ' ' + event.detail.xhr.statusText + '</p>'; document.getElementById('details-dialog').showModal(); }",
                    }) do
                      text "🔍"
                    end
                  end
                  # Context button
                  td(class: "hover-action-cell", style: "width: 1%; white-space: nowrap; text-align: center; padding: 0.1em;") do
                    button({
                      "class"                     => "round-button emoji",
                      "title"                     => "View context for this log entry (e.g., 5 before & 5 after)",
                      "hx-get"                    => "context?#{URI::Params.encode({"cursor" => cursor})}",
                      "hx-target"                 => "#details-dialog-content",
                      "hx-swap"                   => "innerHTML",
                      "hx-on:htmx:before-request" => "document.getElementById('details-dialog-content').innerHTML = document.getElementById('details-dialog-loading-spinner-template').innerHTML;",
                      "hx-on:htmx:after-request"  => "if(event.detail.successful) { document.getElementById('details-dialog').showModal(); } else { document.getElementById('details-dialog-content').innerHTML = '<p class=\\'error\\'>Failed to load details. Status: ' + event.detail.xhr.status + ' ' + event.detail.xhr.statusText + '</p>'; document.getElementById('details-dialog').showModal(); }",
                    }) do
                      text "🕗"
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
