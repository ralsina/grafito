require "kemal"
require "mime"
require "json"
require "./journalctl"
require "./timeline"
require "./grafito_helpers"
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
    file_content = Assets.get(filename)
    content_type = MIME.from_extension("." + filename.split(".").last)
    env.response.content_type = content_type
    env.response.print file_content.gets_to_end
  rescue KeyError
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
    unit_filter_active = !unit.nil? && !unit.strip.empty?
    tag = optional_query_param(env, "tag")
    search_query = optional_query_param(env, "q") # General search term from main input
    priority = optional_query_param(env, "priority")
    current_sort_by = optional_query_param(env, "sort_by")
    current_sort_order = optional_query_param(env, "sort_order")
    format_param = optional_query_param(env, "format")
    output_format = (format_param.presence || "html").downcase

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
      if output_format == "text"
        env.response.content_type = "text/plain"
        output = _generate_text_log_output(logs)
      else # Default to HTML
        env.response.content_type = "text/html"
        output = _generate_html_log_output(logs, current_sort_by, current_sort_order, unit_filter_active, search_query)
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
      options_html = String.build do |sb|
        service_units.each do |unit_name|
          sb << "<option value=\"" << HTML.escape(unit_name) << "\"></option>"
        end
      end
      env.response.print options_html
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

    unless cursor
      env.response.content_type = "text/html"
      halt env, status_code: 400, response: "<p class=\"error\">Missing cursor parameter. Cannot load details.</p>"
    end

    entry = Journalctl.get_entry_by_cursor(cursor)

    if entry
      env.response.content_type = "text/html"
      html_details = String.build do |sb|
        if entry.data.empty?
          sb << "<p>No details available for this log entry.</p>"
        else
          sb << "<pre>"
          sb << entry.to_pretty_json
          sb << "</pre>"
        end
      end
      env.response.print html_details
    else
      env.response.status_code = 404
      env.response.content_type = "text/html"
      env.response.print "<p class=\"error\">Log entry not found for the given cursor.</p>"
    end
  end
end
