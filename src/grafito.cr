require "kemal"
require "json"
require "./journalctl"
require "baked_file_system"

module Grafito
  extend self
  # Setup a logger for this module
  Log = ::Log.for(self)

  VERSION = "0.1.0"

  # Any assets we want baked into the binary.
  class Assets
    extend BakedFileSystem
    bake_file "index.html", {{ read_file "#{__DIR__}/index.html" }}
    bake_file "favicon.svg", {{ read_file "#{__DIR__}/favicon.svg" }}
  end

  # Matches GET "http://host:port/" and serves the index.html file.
  get "/" do |env|
    env.response.content_type = "text/html"
    env.response.print Assets.get("index.html").gets_to_end
  end

  # Matches GET "http://host:port/" and serves the index.html file.
  get "/favicon.svg" do |env|
    env.response.content_type = "image/svg+xml"
    env.response.print Assets.get("favicon.svg").gets_to_end
  end

  # Creates a WebSocket handler.
  # Matches "ws://host:port/socket"
  ws "/socket" do |socket|
    socket.send "Hello from Kemal!"
  end

  # Exposes the Journalctl wrapper via a REST API.
  # Example usage:
  #   GET /logs?unit=sshd.service&tag=sshd
  #   GET /logs?unit=nginx.service&since=-1h
  get "/logs" do |env|
    Log.debug { "Received /logs request with query params: #{env.params.query.inspect}" }

    # If since_param is nil, it means "Any time" was selected.
    since = env.params.query["since"]?
    since = (since && !since.strip.empty?) ? since : nil

    unit = env.params.query["unit"]?
    tag = env.params.query["tag"]?
    search_query = env.params.query["q"]? # General search term from main input
    priority = env.params.query["priority"]?
    priority = (priority && !priority.strip.empty?) ? priority : nil
    current_sort_by = env.params.query["sort_by"]?
    current_sort_order = env.params.query["sort_order"]?

    Log.debug { "Querying Journalctl with: since=#{since.inspect}, unit=#{unit.inspect}, tag=#{tag.inspect}, q=#{search_query.inspect}, priority=#{priority.inspect}, sort_by=#{current_sort_by.inspect}, sort_order=#{current_sort_order.inspect}" }

    logs = Journalctl.query(
      since: since,
      unit: unit,
      tag: tag,
      query: search_query,
      priority: priority,
      sort_by: current_sort_by,
      sort_order: current_sort_order
    )

    env.response.content_type = "text/html" # Set content type for all responses

    # Helper to generate attributes for sortable table headers
    header_attrs_generator = ->(column_key_name : String, display_text : String) do
      sort_indicator = ""
      next_sort_order_for_click = "asc" # Default next sort is ascending

      if current_sort_by == column_key_name
        if current_sort_order == "asc"
          sort_indicator = " <span aria-hidden=\"true\">▲</span>" # Up arrow for ascending
          next_sort_order_for_click = "desc"                      # Next click will be descending
        elsif current_sort_order == "desc"
          sort_indicator = " <span aria-hidden=\"true\">▼</span>" # Down arrow for descending
          next_sort_order_for_click = "asc"                       # Next click will be ascending
        else                                                      # current_sort_order is nil or something else, treat as unsorted for this column
          next_sort_order_for_click = "asc"
        end
      end

      vals_json = String.build do |s|
        s << %({"sort_by": ") << column_key_name << %(", "sort_order": ") << next_sort_order_for_click << %("})
      end

      {
        text:     display_text + sort_indicator,
        hx_vals:  vals_json,
        key_name: column_key_name,
      }
    end

    if logs
      html_output = String.build do |str|
        # Added "striped" class for PicoCSS styling, and some inline style for the empty message
        str << "<table class=\"striped\">"
        str << "<thead><tr>"
        [
          header_attrs_generator.call("timestamp", "Timestamp"),
          header_attrs_generator.call("priority", "Priority"),
          header_attrs_generator.call("message", "Message"),
        ].each do |header|
          str << "<th style=\"cursor: pointer;\" hx-get=\"/logs\" hx-vals='" << header[:hx_vals] << "' hx-include=\"#search-box, #unit-filter, #tag-filter, #priority-filter, #time-range-filter, #live-view\" hx-target=\"#results\" hx-indicator=\"#loading-spinner\">" << header[:text] << "</th>"
        end
        str << "</tr></thead>"
        str << "<tbody>"
        if logs.empty?
          str << "<tr><td colspan=\"3\" style=\"text-align: center; padding: 1em;\">No log entries found.</td></tr>"
        else
          # Helper to get a background color style based on priority
          get_priority_style = ->(priority_value : String) do
            case priority_value
            when "0" then "background-color: #5c0000; color: #f8f8f8;" # Emergency (Darkest Red, Light Text)
            when "1" then "background-color: #7c0a0a; color: #f8f8f8;" # Alert (Dark Red, Light Text)
            when "2" then "background-color: #a04000; color: #f8f8f8;" # Critical (Dark Orange/Brown, Light Text)
            when "3" then "background-color: #905000; color: #f8f8f8;" # Error (Dark Orange, Light Text)
            when "4" then "background-color: #847500; color: #f8f8f8;" # Warning (Dark Yellow/Olive, Light Text)
            when "5" then "background-color: #003366; color: #f8f8f8;" # Notice (Dark Blue, Light Text)
            when "6" then "background-color: #2a3b4d; color: #f8f8f8;" # Informational (Dark Slate Blue/Grey, Light Text)
            when "7" then "background-color: #333333; color: #f0f0f0;" # Debug (Dark Grey, Light Text)
            else            ""                                         # Default: no specific style (will use table striping)
            end
          end

          logs.each do |entry|
            priority_style = get_priority_style.call(entry.priority)
            str << "<tr"
            str << " style=\"" << priority_style << "\"" if !priority_style.empty?
            str << ">"
            str << "<td>" << entry.formatted_timestamp << "</td>"
            str << "<td>" << HTML.escape(entry.formatted_priority) << "</td>"
            str << "<td style=\"white-space: normal; overflow-wrap: break-word; word-wrap: break-word; max-width: 60vw;\">" << HTML.escape(entry.message) << "</td>" # Adjusted max-width slightly
            str << "</tr>"
          end
        end
        str << "</tbody></table>"
      end
      env.response.print html_output
    else
      env.response.status_code = 500
      env.response.print "<p style=\"color: red; text-align: center; padding: 1em;\">Failed to retrieve logs. Please check server logs for more details.</p>"
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

    since = env.params.query["since"]?
    since = (since && !since.strip.empty?) ? since : nil

    unit = env.params.query["unit"]?
    unit = (unit && !unit.strip.empty?) ? unit : nil

    tag = env.params.query["tag"]?
    tag = (tag && !tag.strip.empty?) ? tag : nil

    search_query = env.params.query["q"]?
    search_query = (search_query && !search_query.strip.empty?) ? search_query : nil

    priority = env.params.query["priority"]?
    priority = (priority && !priority.strip.empty?) ? priority : nil

    Log.debug { "Building command with: since=#{since.inspect}, unit=#{unit.inspect}, tag=#{tag.inspect}, q=#{search_query.inspect}, priority=#{priority.inspect}" }
    command_array = Journalctl.build_query_command(since: since, unit: unit, tag: tag, query: search_query, priority: priority)
    env.response.content_type = "text/plain"
    env.response.print "\"#{command_array.join(" ")}\""
  end
end
