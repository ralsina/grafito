# # The Grafito Module
#
# This module defines the API for the grafito backend.
#
# Since Grafito is not a very complicated application, the backend is just a few endpoints
# exposing enough functionality to let you access log information. Because it's all
# read only, they all use the `GET` method.
#
# Some of them have perhaps too many arguments because they have grown following the UI
# and could use some refactoring.

require "./grafito_helpers"
require "./journalctl"
require "./timeline"
require "json"
require "kemal"
require "mime"

module Grafito
  extend self
  # Setup a logger for this module.
  Log = ::Log.for(self)

  # Obtain the version number automatically at compile time from [shard.yml](../shard.yml.html)
  VERSION = {{ `shards version #{__DIR__}/../`.chomp.stringify }} # Adjusted path for shards version

  # Global unit restriction - when set, only logs from these units will be shown
  class_property allowed_units : Array(String)? = nil

  # AI feature flag - when true, AI features are enabled
  class_property? ai_enabled : Bool = false

  # Timezone configuration for timestamp display
  class_property timezone : String = "local"

  # ## The `/logs` endpoint
  #
  # Exposes the Journalctl wrapper via a REST API.
  # Example usage:
  #   ```text
  #   GET /logs?unit=sshd.service&tag=sshd
  #   GET /logs?unit=nginx.service&since=-1h
  #   ```
  # In general all the parameters are derived from the journalctl CLI
  get "/logs" do |env|
    Log.debug { "Received /logs request with query params: #{env.params.query.inspect}" }
    # A time definition. For example: `-1w` means "since 1 week ago"
    since = optional_query_param(env, "since")
    # What systemd unit do we want to see logs for.
    unit = optional_query_param(env, "unit")
    # Filter logs by syslog tag
    tag = optional_query_param(env, "tag")
    # General search term from main input. Can be a regex and is matched to the message field.
    search_query = optional_query_param(env, "q")
    # Filter logs by priority. All priorities "less important" than the requested one will be ignored.
    priority = optional_query_param(env, "priority")
    # Filter logs by hostname (you can concentrate logs from multiple hosts!)
    hostname = optional_query_param(env, "hostname")
    # The UI allows for sorting by different fields
    current_sort_by = optional_query_param(env, "sort_by")
    current_sort_order = optional_query_param(env, "sort_order")
    # This endpoint can return in both HTML or text formats. HTML is useful because
    # the frontend is written using [HTMX](https://htmx.org)
    format_param = optional_query_param(env, "format")

    # Determine column visibility from query parameters. The frontend allows
    # choosing which fields of the log entries are visible.
    show_timestamp_col = env.params.query.has_key?("col-visible-timestamp")
    show_hostname_col = env.params.query.has_key?("col-visible-hostname")
    show_unit_col = env.params.query.has_key?("col-visible-unit")
    show_priority_col = env.params.query.has_key?("col-visible-priority")
    show_message_col = env.params.query.has_key?("col-visible-message")

    output_format = (format_param.presence || "html").downcase
    Log.debug { "Querying Journalctl with: since=#{since.inspect}, unit=#{unit.inspect}, tag=#{tag.inspect}, q=#{search_query.inspect}, priority=#{priority.inspect}, hostname=#{hostname.inspect}, sort_by=#{current_sort_by.inspect}, sort_order=#{current_sort_order.inspect}, show_timestamp=#{show_timestamp_col}, show_hostname=#{show_hostname_col}, show_unit=#{show_unit_col}, show_priority=#{show_priority_col}, show_message=#{show_message_col}" }

    # Now that we know exactly what logs we want, we send the query to the `journalctl` wrapper
    # defined in [journalctl.cr](journalctl.cr.html).
    logs = Journalctl.query(
      since: since,
      unit: unit,
      tag: tag,
      query: search_query,
      priority: priority,
      hostname: hostname,
      sort_by: current_sort_by,
      sort_order: current_sort_order
    )

    # If there are no logs matching our filters logs will be Nil.
    if logs
      # But if we *do* have logs, we use one of two helpers to
      # create the actual responses.
      if output_format == "text"
        env.response.content_type = "text/plain"
        output = _generate_text_log_output(logs)
      else # Default to HTML
        env.response.content_type = "text/html"
        output = html_log_output(
          logs,
          current_sort_by,
          current_sort_order,
          search_query,
          show_timestamp: show_timestamp_col,
          show_hostname: show_hostname_col,
          show_unit: show_unit_col,
          show_priority: show_priority_col,
          show_message: show_message_col
        )
      end
      env.response.print output
    else
      # If we failed to retrieve logs, we raise an error.
      # Probably 500 is the wrong one, and it should be a 404?
      env.response.status_code = 500
      if output_format == "text"
        env.response.content_type = "text/plain"
      else # Default to HTML for errors too
        env.response.content_type = "text/html"
      end
      env.response.print "Failed to retrieve logs."
    end
  end

  # ## The `/services` endpoint
  #
  # Exposes the list of known service units. The frontend uses
  # it for autocomplete.
  # Example usage:
  # ```text
  # GET /services
  # ```
  get "/services" do |env|
    Log.debug { "Received /services request" }
    # Here `known_service_units` is a wrapper around systemctl.
    service_units = Journalctl.known_service_units
    env.response.content_type = "text/html"

    if service_units
      # Build HTML options using html_builder
      env.response.print(
        HTML.build do
          service_units.each do |unit_name|
            option(value: HTML.escape(unit_name)) { }
          end
        end
      )
    else
      # This should never happen unless something is broken in the system.
      env.response.status_code = 500
      env.response.print "<!-- Failed to retrieve service units -->"
    end
  end

  # ## The `/command` endpoint
  #
  # Exposes the command that would be run by /logs with the given parameters.
  # Example usage:
  # ```text
  # GET /command?since=-1h&unit=nginx.service&q=error`
  # ```
  #
  # The frontend uss this to show what the `journalctl` command equivalent to the
  # configured filters would be.

  get "/command" do |env|
    Log.debug { "Received /command request with query params: #{env.params.query.inspect}" }

    since = optional_query_param(env, "since")
    unit = optional_query_param(env, "unit")
    tag = optional_query_param(env, "tag")
    search_query = optional_query_param(env, "q")
    priority = optional_query_param(env, "priority")
    hostname = optional_query_param(env, "hostname") # Also add to /command endpoint for consistency
    Log.debug { "Building command with: since=#{since.inspect}, unit=#{unit.inspect}, tag=#{tag.inspect}, q=#{search_query.inspect}, priority=#{priority.inspect}, hostname=#{hostname.inspect}" }
    # Here `build_query_command` is the same function used by `Journalctl.query` so the command line
    # should always be correct.
    command_array = Journalctl.build_query_command(since: since, unit: unit, tag: tag, query: search_query, priority: priority, hostname: hostname)
    env.response.content_type = "text/plain"
    env.response.print "\"#{command_array.join(" ")}\""
  end

  # ## The `/details` endpoint
  #
  # Exposes detailed information for a single log entry based on its cursor.
  # Example usage:
  # ```text
  # GET /details?cursor=<CURSOR_STRING>`
  # ```
  #
  # It will return a "pretty JSON" representation of the raw log entry
  # represented by the `cursor`
  get "/details" do |env|
    Log.debug { "Received /details request with query params: #{env.params.query.inspect}" }
    cursor = optional_query_param(env, "cursor")
    env.response.content_type = "text/html"

    # If there is no cursor, error out.
    unless cursor
      halt env, status_code: 400, response: "Missing cursor parameter. Cannot load details."
    end

    if entry = Journalctl.get_entry_by_cursor(cursor)
      HTML.build do
        # We have no data for the entry, just show a message
        if entry.data.empty?
          p do # ameba:disable Lint/DebugCalls
            text "No details available for this log entry."
          end
        else
          # Create a pretty JSON version of the raw entry
          tag("pre") do
            text entry.to_pretty_json
          end
        end
      end
    else
      # We didn't find the entry, so error out with a 404
      env.response.status_code = 404
      env.response.print "Log entry not found for the given cursor."
    end
  end

  # ## The `/context` endpoint
  #
  # Exposes log entry context (entries before and after a given cursor).
  # Example usage:
  # ```text
  # GET /context?cursor=<CURSOR_STRING>&count=5`
  # ```
  #
  # Works like `/query` but it will return some of the log entries
  # that are around the requested one for context.
  get "/context" do |env|
    Log.debug { "Received /context request with query params: #{env.params.query.inspect}" }
    cursor = optional_query_param(env, "cursor")
    count_str = optional_query_param(env, "count")

    unless cursor
      env.response.content_type = "text/html"
      halt env, status_code: 400, response: "<p class=\"error\">Missing cursor parameter. Cannot load context.</p>"
    end

    # Default to 5 if not provided or invalid
    count = count_str.try(&.to_i?) || 5
    if count <= 0
      env.response.content_type = "text/html"
      halt env, status_code: 400, response: "<p class=\"error\">Context count must be positive.</p>"
    end

    # Get `count` entries before and after the cursor
    context_entries = Journalctl.context(cursor, count)

    env.response.content_type = "text/html"
    if context_entries
      # Retain the specific title for the context view
      title_html = "<h4>Log Context (#{count} before & after)</h4>"

      # For context view, we generally want to see all columns, including Unit.
      # Sorting and search query are not directly applicable here, and we don´t
      # want the `chart`, a timeline of events, since they are all consecutive
      # in a short period.
      generated_table_html = html_log_output(
        context_entries,          # The logs to display
        nil,                      # current_sort_by
        nil,                      # current_sort_order
        nil,                      # search_query
        chart: false,             # No chart in context view
        highlight_cursor: cursor, # Highlight the original entry
        show_timestamp: true,     # Always show all columns in context view
        show_hostname: true,
        show_unit: true,
        show_priority: true,
        show_message: true
      )

      # Combine the custom title with the table generated by the helper
      env.response.print title_html + generated_table_html
    else
      # Journalctl.context might return nil if the original cursor was not found
      # or if the count was invalid (though we check count above).
      env.response.print "<p class=\"error\">Could not retrieve context for cursor: #{HTML.escape(cursor)}. The entry might not exist or an error occurred.</p>"
    end
  end

  # ## The `/ask-ai` endpoint
  #
  # Sends log context to z.ai for AI-powered explanation.
  # Example usage:
  # ```text
  # POST /ask-ai
  # Content-Type: application/json
  # {"cursor": "<CURSOR_STRING>"}
  # ```
  #
  # Returns JSON with AI explanation or error message.
  post "/ask-ai" do |env|
    Log.debug { "Received /ask-ai request" }

    # Check if AI is enabled
    unless ai_enabled?
      env.response.content_type = "application/json"
      env.response.status_code = 503
      next {error: "AI features are disabled. Configure Z_AI_API_KEY environment variable to enable."}.to_json
    end

    # Parse JSON request body
    body = env.request.body.try(&.gets_to_end) || ""
    if body.empty?
      env.response.content_type = "application/json"
      env.response.status_code = 400
      next {error: "Request body is empty."}.to_json
    end

    begin
      json_body = JSON.parse(body)
      cursor = json_body["cursor"]?.try(&.as_s)

      unless cursor
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next {error: "Missing 'cursor' parameter in request body."}.to_json
      end

      # Get context entries (5 before and after)
      context_entries = Journalctl.context(cursor, 5)
      unless context_entries
        env.response.content_type = "application/json"
        env.response.status_code = 404
        next {error: "Could not retrieve context for cursor: #{cursor}"}.to_json
      end

      # Find the target entry (the one at position 5, assuming 5 entries before)
      target_entry = context_entries[5]?
      unless target_entry
        env.response.content_type = "application/json"
        env.response.status_code = 404
        next {error: "Target log entry not found in context"}.to_json
      end

      # Build context text for AI
      context_lines = context_entries.map_with_index do |entry, index|
        marker = index == 5 ? ">>> LINE 6 (TARGET): " : "    "
        "#{marker}[#{entry.timestamp}] [#{entry.formatted_priority}] [#{entry.unit || "N/A"}] #{entry.message}"
      end.join("\n")

      prompt = "Please explain the error in the highlighted log entry of this context. Focus on what the error means, potential causes, and suggested solutions. Be concise and helpful."

      # Call z.ai API
      api_key = ENV["Z_AI_API_KEY"]?
      unless api_key
        env.response.content_type = "application/json"
        env.response.status_code = 500
        next {error: "Z_AI_API_KEY environment variable not set."}.to_json
      end

      headers = HTTP::Headers{
        "Authorization"   => "Bearer #{api_key}",
        "Content-Type"    => "application/json",
        "Accept-Language" => "en-US,en",
      }

      z_ai_body = {
        "model"    => "glm-4.5-flash",
        "messages" => [
          {"role" => "system", "content" => "You are a helpful AI assistant specializing in system log analysis. Provide clear, concise explanations of log errors with practical solutions."},
          {"role" => "user", "content" => "#{prompt}\n\nLog Context:\n#{context_lines}"},
        ],
      }

      uri = URI.parse("https://api.z.ai/api/paas/v4/chat/completions")
      client = HTTP::Client.new(uri)
      response = client.post(uri.path, headers, z_ai_body.to_json)

      env.response.content_type = "application/json"
      env.response.status_code = response.status_code
      response.body
    rescue ex : JSON::ParseException
      env.response.content_type = "application/json"
      env.response.status_code = 400
      {error: "Invalid JSON in request body: #{ex.message}"}.to_json
    rescue ex : Exception
      env.response.content_type = "application/json"
      env.response.status_code = 500
      Log.error(exception: ex) { "Error calling z.ai API: #{ex.message}" }
      {error: "Error processing AI request: #{ex.message}"}.to_json
    end
  end
end
