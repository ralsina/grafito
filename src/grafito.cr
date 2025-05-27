require "kemal"
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

  get "/" do |env|
    env.redirect "/index.html"
  end

  get "/:file" do |env|
    filename = env.params.url["file"]
    content_type = case File.extname(filename)
                   when ".css"  then "text/css"
                   when ".js"   then "application/javascript"
                   when ".svg"  then "image/svg+xml"
                   when ".html" then "text/html"
                     # Add other common types as needed, e.g., .png, .jpg, .woff2
                   else "application/octet-stream" # A generic default
                   end
    env.response.content_type = content_type
    env.response.print Assets.get(filename).gets_to_end
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
    unit_filter_active = unit.is_a?(String) && !unit.strip.empty?
    tag = env.params.query["tag"]?
    search_query = env.params.query["q"]? # General search term from main input
    priority = env.params.query["priority"]?
    priority = (priority && !priority.strip.empty?) ? priority : nil
    current_sort_by = env.params.query["sort_by"]?
    current_sort_order = env.params.query["sort_order"]?

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
        # Generate and add the timeline SVG
        # Pass an empty array to generate_frequency_timeline if logs is nil,
        # though in this block, logs is guaranteed to be non-nil.
        # The generate_svg_timeline function handles empty timeline_data gracefully.
        timeline_data = Timeline.generate_frequency_timeline(logs)
        # You can customize SVG dimensions and other parameters here if needed
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
        str << "<p style=\"text-align: right; margin-bottom: 0.5em; font-style: italic; font-size: 0.9em; color: #777777;\">#{count_message}</p>"
        str << "<table class=\"striped\">"

        headers_to_display = [header_attrs_generator.call("timestamp", "Timestamp")]
        unless unit_filter_active # Only add Service header if unit filter is NOT active
          headers_to_display << header_attrs_generator.call("service", "Unit")
        end
        headers_to_display << header_attrs_generator.call("priority", "Priority")
        headers_to_display << header_attrs_generator.call("message", "Message")

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
          # Returns a class name string like "priority-0" or an empty string
          get_priority_class_name = ->(p : Int32) do
            case p
            when 0 then "priority-0" # Emergency
            when 1 then "priority-1" # Alert
            when 2 then "priority-2" # Critical
            when 3 then "priority-3" # Error
            when 4 then "priority-4" # Warning
            # Priorities 5, 6, 7 will not get a special class and use default styles
            else ""
            end
          end

          logs.each do |entry|
            priority_class = get_priority_class_name.call(entry.priority.to_i32)

            str << "<tr"
            str << " class=\"" << priority_class << "\"" if !priority_class.empty?
            str << ">"

            # Timestamp
            str << "<td>" << entry.formatted_timestamp << "</td>"

            unless unit_filter_active # Only add Service data cell if unit filter is NOT active
              str << "<td>" << HTML.escape(entry.unit) << "</td>"
            end
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
