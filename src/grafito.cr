require "kemal"
require "mime"
require "json"
require "./journalctl"
require "./timeline"
require "baked_file_system"

module Grafito
  extend self
  # Setup a logger for this module
  Log = ::Log.for(self)

  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}

  # Any assets we want baked into the binary.
  class Assets
    extend BakedFileSystem
    bake_file "index.html", {{ read_file "#{__DIR__}/index.html" }}
    bake_file "favicon.svg", {{ read_file "#{__DIR__}/favicon.svg" }}
    bake_file "style.css", {{ read_file "#{__DIR__}/style.css" }}
  end

  # Helper to get an optional query parameter, treating empty strings as nil.
  private def optional_query_param(env : HTTP::Server::Context, key : String) : String?
    param = env.params.query[key]?
    return nil if param.nil? || param.strip.empty?
    param
  end

  # Generates attributes for sortable table headers.
  # Returns a NamedTuple with text, hx_vals (JSON string), and key_name.
  private def _generate_header_attributes(column_key_name : String, display_text : String, current_sort_by : String?, current_sort_order : String?) : NamedTuple(text: String, hx_vals: String, key_name: String)
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
          unless unit_filter_active
            str << " [" << entry.unit << "]"
          end
          str << " (" << entry.formatted_priority << ") "
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

      str << "<thead><tr>"
      headers_to_display.each do |header|
        str << "<th style=\"cursor: pointer;\" hx-get=\"/logs\" hx-vals='" << header[:hx_vals] << "' hx-include=\"#search-box, #unit-filter, #tag-filter, #priority-filter, #time-range-filter, #live-view\" hx-target=\"#results\" hx-indicator=\"#loading-spinner\">" << header[:text] << "</th>"
      end
      str << "</tr></thead>"
      str << "<tbody>"

      colspan_value = unit_filter_active ? 3 : 4

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
          str << "</tr>"
        end
      end
      str << "</tbody></table>"
    end
  end

  get "/" do |env|
    env.redirect "/index.html"
  end

  get "/:file" do |env|
    filename = env.params.url["file"]
    file_content = Assets.get(filename)
    content_type = MIME.from_extension("." + filename.split(".").last)
    env.response.content_type = content_type
    env.response.print file_content.gets_to_end
  rescue KeyError # Or a more specific error if BakedFileSystem provides one
    env.response.status_code = 404
    env.response.print "File not found"
  end

  # Exposes the Journalctl wrapper via a REST API.
  # Example usage:
  #   GET /logs?unit=sshd.service&tag=sshd
  #   GET /logs?unit=nginx.service&since=-1h
  get "/logs" do |env|
    Log.debug { "Received /logs request with query params: #{env.params.query.inspect}" }

    since = optional_query_param(env, "since")
    unit = optional_query_param(env, "unit")
    unit_filter_active = unit.is_a?(String) && !unit.strip.empty?
    tag = optional_query_param(env, "tag")
    search_query = optional_query_param(env, "q") # General search term from main input
    priority = optional_query_param(env, "priority")
    current_sort_by = optional_query_param(env, "sort_by")
    current_sort_order = optional_query_param(env, "sort_order")
    format_param = optional_query_param(env, "format")
    output_format = format_param.presence || "html"

    Log.debug { "Querying Journalctl with: since=#{since.inspect}, unit=#{unit.inspect} (filter active: #{unit_filter_active}), tag=#{tag.inspect}, q=#{search_query.inspect}, priority=#{priority.inspect}, sort_by=#{current_sort_by.inspect}, sort_order=#{current_sort_order.inspect}" }

    logs = Journalctl.query(
      since: since,
      unit: unit,
      tag: tag,
      query: search_query,
      priority: priority,
      sort_by: current_sort_by,
      sort_order: current_sort_order
    )

    if logs
      if output_format.downcase == "text"
        env.response.content_type = "text/plain"
        text_output = _generate_text_log_output(logs, unit_filter_active)
        env.response.print text_output
      else # Default to HTML
        env.response.content_type = "text/html"
        html_output = _generate_html_log_output(logs, current_sort_by, current_sort_order, unit_filter_active, search_query)
        env.response.print html_output
      end
    else # Failed to retrieve logs
      env.response.status_code = 500
      if output_format.downcase == "text"
        env.response.content_type = "text/plain"
        env.response.print "Failed to retrieve logs. Please check server logs for more details."
      else # Default to HTML for errors too
        env.response.content_type = "text/html"
        env.response.print "<p class=\"error\">Failed to retrieve logs. Please check server logs for more details.</p>"
      end
    end
  end

  # Exposes the list of known service units.
  # Example usage:
  #   GET /services
  get "/services" do |env|
    Log.debug { "Received /services request" }
    service_units = Journalctl.known_service_units
    env.response.content_type = "text/html" # Changed to text/html

    if service_units
      # Build HTML options
      options_html = String.build do |sb|
        service_units.each do |unit_name|
          sb << "<option value=\"" << HTML.escape(unit_name) << "\"></option>"
        end
      end
      env.response.print options_html
    else
      env.response.status_code = 500
      # Return an HTML comment or an empty string if units can't be fetched.
      # This prevents HTMX from erroring if it expects HTML.
      env.response.print "<!-- Failed to retrieve service units -->"
    end
  end

  # Exposes the command that would be run by /logs with the given parameters.
  # Example usage:
  #   GET /command?since=-1h&unit=nginx.service&q=error
  get "/command" do |env|
    Log.debug { "Received /command request with query params: #{env.params.query.inspect}" }

    since = optional_query_param(env, "since")
    unit = optional_query_param(env, "unit")
    tag = optional_query_param(env, "tag")
    search_query = optional_query_param(env, "q")
    priority = optional_query_param(env, "priority")

    Log.debug { "Building command with: since=#{since.inspect}, unit=#{unit.inspect}, tag=#{tag.inspect}, q=#{search_query.inspect}, priority=#{priority.inspect}" }
    command_array = Journalctl.build_query_command(since: since, unit: unit, tag: tag, query: search_query, priority: priority)
    env.response.content_type = "text/plain"
    env.response.print "\"#{command_array.join(" ")}\""
  end
end
