require "kemal" # For HTTP::Server::Context and HTML
require "json"
require "./journalctl"
require "./timeline"

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
  private def _generate_text_log_output(logs : Array(Journalctl::LogEntry), unit_filter_active : Bool) : String
    String.build do |str|
      if logs.empty?
        str << "No log entries found.\n"
      else
        logs.each do |entry|
          str << entry.formatted_timestamp
          str << " [#{entry.unit}]"
          str << " (#{entry.formatted_priority}) "
          str << entry.message
          str << '\n'
        end
      end
    end
  end

  # Generates an HTML representation of log entries.
  private def _generate_html_log_output(
    logs : Array(Journalctl::LogEntry),
    current_sort_by : String?,
    current_sort_order : String?,
    unit_filter_active : Bool,
    search_query : String?,
  ) : String
    String.build do |str|
      # Generate and add the timeline SVG
      timeline_data = Timeline.generate_frequency_timeline(logs)
      svg_timeline_html = Timeline.generate_svg_timeline(timeline_data)
      str << "<div style=\"margin-bottom: 1em;\">" << svg_timeline_html << "</div>"

      # Display results count
      count_message = if logs.size == 5000
                        "Results limited to latest 5000 entries."
                      elsif logs.size == 1
                        "Showing 1 entry."
                      else
                        "Showing #{logs.size} entries." # Handles 0 and other counts
                      end
      str << "<p class=\"results-count\">#{count_message}</p>"
      str << "<table class=\"striped\">"

      headers_to_display = [_generate_header_attributes("timestamp", "Timestamp", current_sort_by, current_sort_order)]
      unless unit_filter_active # Only add Service header if unit filter is NOT active
        headers_to_display << _generate_header_attributes("service", "Unit", current_sort_by, current_sort_order)
      end
      headers_to_display << _generate_header_attributes("priority", "Priority", current_sort_by, current_sort_order)
      headers_to_display << _generate_header_attributes("message", "Message", current_sort_by, current_sort_order)
      # Add a non-sortable header for Details
      headers_to_display << {text: "Details", hx_vals: "", key_name: "details"} # key_name is arbitrary, hx_vals empty as it's not sortable

      str << "<thead><tr>"
      headers_to_display.each do |header|
        if header[:key_name] == "details"
          str << "<th>" << header[:text] << "</th>" # Non-sortable header
        else
          str << "<th style=\"cursor: pointer;\" hx-get=\"/logs\" hx-vals='" << header[:hx_vals] << "' hx-include=\"#search-box, #unit-filter, #tag-filter, #priority-filter, #time-range-filter, #live-view\" hx-target=\"#results\" hx-indicator=\"#loading-spinner\">" << header[:text] << "</th>"
        end
      end
      str << "</tr></thead>"
      str << "<tbody>"

      colspan_value = (unit_filter_active ? 4 : 5)

      if logs.empty?
        str << "<tr><td colspan=\"#{colspan_value}\" style=\"text-align: center; padding: 1em;\">No log entries found.</td></tr>"
      else
        logs.each do |entry|
          str << "<tr class=\"priority-#{entry.priority.to_i}\" >"
          str << "<td>" << entry.formatted_timestamp << "</td>"
          unless unit_filter_active
            str << "<td>" << HTML.escape(entry.unit) << "</td>"
          end
          str << "<td>" << HTML.escape(entry.formatted_priority) << "</td>"
          escaped_message = HTML.escape(entry.message)
          highlighted_message = if search_query && !search_query.strip.empty?
                                  pattern = Regex.escape(search_query)
                                  escaped_message.gsub(/#{pattern}/i, "<mark>\\0</mark>")
                                else
                                  escaped_message
                                end
          str << "<td class=\"log-message-cell\">" << highlighted_message << "</td>"
          # Add details link/icon cell
          cursor = entry.data["__CURSOR"]?
          if cursor
            str << "<td style=\"text-align: center;\">"
            str << "<button class=\"round-button\" "
            str << "title=\"View full details for this log entry\" "
            str << "hx-get=\"/details?" << URI::Params.encode({"cursor" => cursor}) << "\" "
            str << "hx-target=\"#details-dialog-content\" "
            str << "hx-swap=\"innerHTML\" "
            str << "hx-on:htmx:before-request=\"document.getElementById('details-dialog-content').innerHTML = document.getElementById('details-dialog-loading-spinner-template').innerHTML;\" "
            str << "hx-on:htmx:after-request=\"if(event.detail.successful) { document.getElementById('details-dialog').showModal(); } else { document.getElementById('details-dialog-content').innerHTML = '<p class=\\'error\\'>Failed to load details. Status: ' + event.detail.xhr.status + ' ' + event.detail.xhr.statusText + '</p>'; document.getElementById('details-dialog').showModal(); }\""
            str << ">🔍</button>"
            str << "</td>"
          end
          str << "</tr>"
        end
      end
      str << "</tbody></table>"
    end
  end
end
