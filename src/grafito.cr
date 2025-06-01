require "./grafito_helpers"
require "./journalctl"
require "./timeline"
require "baked_file_system"
require "json"
require "kemal"
require "mime"

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
    bake_file "pico.min.css", {{ read_file "#{__DIR__}/pico.min.css" }}
    bake_file "robots.txt", {{ read_file "#{__DIR__}/robots.txt" }}
    bake_file "htmx.org@1.9.10.js", {{ read_file "#{__DIR__}/htmx.org@1.9.10.js" }}
  end

  def serve_file(env, filename)
    file_content = Assets.get(filename)
    content_type = MIME.from_extension("." + filename.split(".").last)
    env.response.content_type = content_type
    env.response.headers.add("Cache-Control", "max-age=604800")
    env.response.print file_content.gets_to_end
  rescue KeyError
    env.response.status_code = 404
    env.response.print "File not found"
  end

  get "/" do |env|
    serve_file(env, "index.html")
  end

  get "/:file" do |env|
    filename = env.params.url["file"]
    serve_file(env, filename)
  end

  # Exposes the Journalctl wrapper via a REST API.
  # Example usage:
  #   GET /logs?unit=sshd.service&tag=sshd
  #   GET /logs?unit=nginx.service&since=-1h
  get "/logs" do |env|
    Log.debug { "Received /logs request with query params: #{env.params.query.inspect}" }

    since = optional_query_param(env, "since")
    unit = optional_query_param(env, "unit")
    tag = optional_query_param(env, "tag")
    search_query = optional_query_param(env, "q") # General search term from main input
    priority = optional_query_param(env, "priority")
    current_sort_by = optional_query_param(env, "sort_by")
    current_sort_order = optional_query_param(env, "sort_order")
    format_param = optional_query_param(env, "format")
    output_format = (format_param.presence || "html").downcase

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

    if logs
      if output_format == "text"
        env.response.content_type = "text/plain"
        output = _generate_text_log_output(logs)
      else # Default to HTML
        env.response.content_type = "text/html"
        output = html_log_output(logs, current_sort_by, current_sort_order, search_query)
      end
      env.response.print output
    else # Failed to retrieve logs
      env.response.status_code = 500
      if output_format == "text"
        env.response.content_type = "text/plain"
      else # Default to HTML for errors too
        env.response.content_type = "text/html"
      end
      env.response.print "Failed to retrieve logs."
    end
  end

  # Exposes the list of known service units.
  # Example usage:
  #   GET /services
  get "/services" do |env|
    Log.debug { "Received /services request" }
    service_units = Journalctl.known_service_units
    env.response.content_type = "text/html"

    if service_units
      # Build HTML options
      env.response.print(
        HTML.build do
          service_units.each do |unit_name|
            option(value: HTML.escape(unit_name)) { }
          end
        end
      )
    else
      env.response.status_code = 500
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

  # Exposes detailed information for a single log entry based on its cursor.
  # Example usage:
  #   GET /details?cursor=<CURSOR_STRING>
  get "/details" do |env|
    Log.debug { "Received /details request with query params: #{env.params.query.inspect}" }
    cursor = optional_query_param(env, "cursor")
    env.response.content_type = "text/html"

    unless cursor
      halt env, status_code: 400, response: "Missing cursor parameter. Cannot load details."
    end

    if entry = Journalctl.get_entry_by_cursor(cursor)
      HTML.build do
        if entry.data.empty?
          p do # ameba:disable Lint/DebugCalls
            text "No details available for this log entry."
          end
        else
          tag("pre") do
            text entry.to_pretty_json
          end
        end
      end
    else
      env.response.status_code = 404
      env.response.print "Log entry not found for the given cursor."
    end
  end

  # Exposes log entry context (entries before and after a given cursor).
  # Example usage:
  #   GET /context?cursor=<CURSOR_STRING>&count=5
  get "/context" do |env|
    Log.debug { "Received /context request with query params: #{env.params.query.inspect}" }
    cursor = optional_query_param(env, "cursor")
    count_str = optional_query_param(env, "count")

    unless cursor
      env.response.content_type = "text/html"
      halt env, status_code: 400, response: "<p class=\"error\">Missing cursor parameter. Cannot load context.</p>"
    end

    count = count_str.try(&.to_i?) || 5 # Default to 5 if not provided or invalid
    if count <= 0
      env.response.content_type = "text/html"
      halt env, status_code: 400, response: "<p class=\"error\">Context count must be positive.</p>"
    end

    context_entries = Journalctl.context(cursor, count)

    env.response.content_type = "text/html"
    if context_entries
      # Retain the specific title for the context view
      title_html = "<h4>Log Context (#{count} before & after)</h4>"

      # For context view, we generally want to see all columns, including Unit.
      # Sorting and search query are not directly applicable here.
      generated_table_html = html_log_output(
        context_entries,         # The logs to display
        nil,                     # current_sort_by
        nil,                     # current_sort_order
        nil,                     # search_query
        chart: false,            # No chart in context view
        highlight_cursor: cursor # Highlight the original entry
      )

      # Combine the custom title with the table generated by the helper
      env.response.print title_html + generated_table_html
    else
      # Journalctl.context might return nil if the original cursor was not found
      # or if the count was invalid (though we check count above).
      env.response.print "<p class=\"error\">Could not retrieve context for cursor: #{HTML.escape(cursor)}. The entry might not exist or an error occurred.</p>"
    end
  end
end
