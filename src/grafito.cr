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
require "./system_status"
require "./metrics_store"
require "./dashboard"
require "./gotify/config"
require "./gotify/client"
require "./gotify/rules"
require "./ai/config"
require "./ai/provider"
require "./ai/request"
require "./ai/response"
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

  # Idle timeout - when set, will shut down if idle for the set number of seconds
  class_property idle_timeout_sec : Int32 = 0

  # AI provider instance - nil if no provider is configured
  class_property ai_provider : AI::Provider? = nil

  # Convenience method for checking if AI is available (backward compatible)
  def self.ai_enabled? : Bool
    !ai_provider.nil?
  end

  # Timezone configuration for timestamp display
  class_property timezone : String = "local"

  # Base path for deployment (e.g., "/" or "/grafito")
  class_property base_path : String = "/"

  # User systemd mode - when enabled, use --user flag for journalctl/systemctl
  class_property? user_mode : Bool = false

  # Whether basic-auth credentials are configured. Unit actions require
  # them: there is no reason to expose state-changing endpoints on an
  # unauthenticated server.
  class_property? auth_configured : Bool = false

  # Server dashboard - when enabled, /status, /status/history and
  # /dashboard are served and the metrics sampler runs.
  class_property? dashboard_enabled : Bool = true

  # Metrics sampler, nil when the dashboard is disabled (and in specs).
  class_property metrics_store : MetricsStore? = nil

  # When enabled, the dashboard's unit table offers start/stop/restart
  # buttons restricted to the --units whitelist.
  class_property? enable_actions : Bool = false

  # Default time window for the dashboard history chart and error count.
  DEFAULT_DASHBOARD_SINCE = Time.utc - 6.hours

  # Helper to build route paths with proper base path handling
  private def self.route_path(path : String) : String
    if base_path == "/"
      "/" + path
    else
      "#{base_path}/#{path}"
    end
  end

  # Register all Kemal routes (called after base_path is set)
  # ameba:disable Metrics/CyclomaticComplexity
  def self.register_routes
    if idle_timeout_sec > 0
      use IdleShutdownHandler.new(timeout_sec: idle_timeout_sec, logger: Log)
    end
    use CacheHeadersHandler.new
    use GzipHandler.new

    # When deployed under a base path (e.g. /grafito), visitors hitting the
    # bare root (http://host:port/) should land in the app, not a 404.
    if base_path != "/"
      get "/" do |env|
        env.redirect base_path.ends_with?("/") ? base_path : "#{base_path}/"
      end
    end

    # ## The `/logs` endpoint
    #
    # Exposes the Journalctl wrapper via a REST API.
    # Example usage:
    #   ```text
    #   GET /logs?unit=sshd.service&tag=sshd
    #   GET /logs?unit=nginx.service&since=-1h
    #   ```
    # In general all the parameters are derived from the journalctl CLI
    get route_path("logs") do |env|
      Log.debug { "Received #{base_path}/logs request with query params: #{env.params.query.inspect}" }
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
      show_tag_col = env.params.query.has_key?("col-visible-tag")
      show_priority_col = env.params.query.has_key?("col-visible-priority")
      show_message_col = env.params.query.has_key?("col-visible-message")

      output_format = (format_param.presence || "html").downcase
      Log.debug { "Querying Journalctl with: since=#{since.inspect}, unit=#{unit.inspect}, tag=#{tag.inspect}, q=#{search_query.inspect}, priority=#{priority.inspect}, hostname=#{hostname.inspect}, sort_by=#{current_sort_by.inspect}, sort_order=#{current_sort_order.inspect}, show_timestamp=#{show_timestamp_col}, show_hostname=#{show_hostname_col}, show_unit=#{show_unit_col}, show_tag=#{show_tag_col}, show_priority=#{show_priority_col}, show_message=#{show_message_col}" }

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
            show_tag: show_tag_col,
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
    get route_path("services") do |env|
      Log.debug { "Received #{base_path}/services request" }
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

    get route_path("command") do |env|
      Log.debug { "Received #{base_path}/command request with query params: #{env.params.query.inspect}" }

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
    get route_path("details") do |env|
      Log.debug { "Received #{base_path}/details request with query params: #{env.params.query.inspect}" }
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
            # Pretty JSON of the raw entry, with the fields sorted
            # alphabetically so they are easy to scan.
            sorted_json = String.build do |str|
              JSON.build(str, indent: "  ") do |json|
                json.object do
                  entry.data.to_a.sort_by(&.[0]).each do |field_name, value|
                    json.field(field_name, value)
                  end
                end
              end
            end
            div(style: "text-align: right; margin-bottom: 0.5em;") do
              tag("button", class: "secondary", onclick: "copyTextToClipboard(document.getElementById('detail-json').textContent, this)") do
                tag("span", class: "material-icons", style: "vertical-align: middle; font-size: 1rem") do
                  text "content_copy"
                end
                text " Copy data"
              end
            end
            tag("pre", id: "detail-json") do
              text sorted_json
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
    get route_path("context") do |env|
      Log.debug { "Received #{base_path}/context request with query params: #{env.params.query.inspect}" }
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

    # ## The `/ai-providers` endpoint
    #
    # Returns list of available AI providers that the user can switch between.
    #
    # Example usage:
    # ```text
    # GET /ai-providers
    # ```
    #
    # Returns JSON array of providers with id, name, and availability.
    get route_path("ai-providers") do |env|
      env.response.content_type = "application/json"

      providers = AI::Config.available_providers

      # A provider configured through endpoint overrides (e.g. a local
      # proxy) may not have any API-key env var for the availability list.
      # Expose it as a synthetic "default" entry so the UI stays usable.
      if providers.empty? && (active = Grafito.ai_provider)
        providers = [AI::Config::ProviderInfo.new(
          id: "default",
          name: active.name,
          available: true,
        )]
      end

      current = Grafito.ai_provider.try(&.name)

      {
        providers: providers,
        current:   current,
        enabled:   AI::Config.enabled?,
      }.to_json
    end

    # ## The `/ai-models` endpoint
    #
    # Returns list of available models for a specific provider.
    # Models are fetched dynamically from the provider's API when possible.
    #
    # Example usage:
    # ```text
    # GET /ai-models?provider=openai
    # ```
    #
    # Returns JSON array of models with id, name, and default flag.
    get route_path("ai-models") do |env|
      env.response.content_type = "application/json"

      provider_id = env.params.query["provider"]?

      unless provider_id
        env.response.status_code = 400
        next {error: "Missing 'provider' query parameter"}.to_json
      end

      models = AI::Config.models_for_provider(provider_id)

      # The synthetic "default" provider has no models endpoint; report the
      # active provider's current model so the UI selector stays usable.
      if models.empty? && provider_id == "default" && (active = Grafito.ai_provider)
        models = [AI::ModelInfo.new(
          id: active.current_model,
          name: active.current_model,
          default: true,
        )]
      end

      {models: models}.to_json
    end

    # ## The `/ask-ai` endpoint
    #
    # Sends log context to the configured AI provider for explanation.
    # Supports multiple providers (Anthropic, OpenAI-compatible APIs).
    #
    # Example usage:
    # ```text
    # POST /ask-ai
    # Content-Type: application/json
    # {"cursor": "<CURSOR_STRING>", "provider": "anthropic"}
    # ```
    #
    # Returns JSON with AI explanation or error message.
    post route_path("ask-ai") do |env|
      Log.debug { "Received #{base_path}/ask-ai request" }

      # Parse JSON to check for provider/model override
      body = env.request.body.try(&.gets_to_end) || ""
      provider_id : String? = nil
      model_id : String? = nil
      cursor : String? = nil
      history = [] of Hash(String, String)

      unless body.empty?
        begin
          json_body = JSON.parse(body)
          cursor = json_body["cursor"]?.try(&.as_s)
          provider_id = json_body["provider"]?.try(&.as_s)
          model_id = json_body["model"]?.try(&.as_s)
          if raw_history = json_body["history"]?.try(&.as_a)
            raw_history.each do |item|
              role = item["role"]?.try(&.as_s)
              content = item["content"]?.try(&.as_s)
              if role && content && (role == "user" || role == "assistant")
                history << {"role" => role, "content" => content}
              end
            end
          end
        rescue
          # Will be handled below
        end
      end

      # Get provider (either specified or default), with optional model.
      # A requested provider that isn't actually usable in this process
      # (e.g. remembered in the UI but its API key is not set) falls back
      # to the default provider instead of failing mid-request.
      requested_provider = if pid = provider_id
                             AI::Config.provider_by_id(pid, model_id)
                           end
      provider = if requested_provider && requested_provider.available?
                   requested_provider
                 else
                   Grafito.ai_provider
                 end

      unless provider
        env.response.content_type = "application/json"
        env.response.status_code = 503
        next {
          error: "AI features are disabled. Configure ANTHROPIC_API_KEY or Z_AI_API_KEY environment variable to enable.",
          hint:  "See documentation for supported providers.",
        }.to_json
      end

      begin
        unless cursor
          env.response.content_type = "application/json"
          env.response.status_code = 400
          next {error: "Missing 'cursor' parameter in request body."}.to_json
        end

        # Get context entries (5 before and after)
        context_count = 5
        context_entries = Journalctl.context(cursor, context_count)
        unless context_entries
          env.response.content_type = "application/json"
          env.response.status_code = 404
          next {error: "Could not retrieve context for cursor: #{cursor}"}.to_json
        end

        # Find the target entry by matching its cursor in the context; fall
        # back to the middle position (count entries before the target) if
        # journalctl didn't report cursors for some reason.
        target_entry = context_entries.find { |entry| entry.data["__CURSOR"]? == cursor } ||
                       context_entries[context_count]?
        unless target_entry
          env.response.content_type = "application/json"
          env.response.status_code = 404
          next {error: "Target log entry not found in context"}.to_json
        end

        # Build context text for AI
        context_lines = context_entries.map do |entry|
          marker = entry.same?(target_entry) ? ">>> LINE (TARGET): " : "    "
          "#{marker}[#{entry.timestamp}] [#{entry.formatted_priority}] [#{entry.unit || "N/A"}] #{entry.message}"
        end.join("\n")

        # Create normalized AI request with priority-aware prompts
        request = AI::Request.for_log_analysis(context_lines, target_entry.priority)

        # Iterative refinement: replay prior conversation turns as real
        # messages so the model continues the discussion about this log
        # entry. The client sends the follow-up question as the last turn.
        if !history.empty?
          request = AI::Request.new(
            system_prompt: request.system_prompt,
            user_prompt: request.user_prompt,
            max_tokens: request.max_tokens,
            temperature: request.temperature,
            history: history,
          )
        end

        # Execute completion via the provider abstraction
        Log.debug { "Calling AI provider: #{provider.name}" }
        response = provider.complete(request)
        Log.debug { "AI response received (#{response.content.size} chars)" }

        # Return normalized response
        env.response.content_type = "application/json"
        {
          content:  response.content,
          model:    response.model,
          provider: response.provider,
          usage:    response.usage,
        }.to_json
      rescue ex : JSON::ParseException
        env.response.content_type = "application/json"
        env.response.status_code = 400
        {error: "Invalid JSON in request body: #{ex.message}"}.to_json
      rescue ex : Exception
        env.response.content_type = "application/json"
        env.response.status_code = 500
        Log.error(exception: ex) { "AI provider error: #{ex.message}" }
        {error: "AI request failed: #{ex.message}"}.to_json
      end
    end

    # ## The `/status` endpoint
    #
    # Returns the current system snapshot (metrics + unit states) plus a
    # bounded journal error count, as JSON.
    #
    # Example usage:
    # ```text
    # GET /status
    # ```
    get route_path("status") do |env|
      unless Grafito.dashboard_enabled?
        env.response.content_type = "application/json"
        env.response.status_code = 404
        next {error: "Dashboard is disabled"}.to_json
      end

      snapshot = SystemStatus.snapshot
      env.response.content_type = "application/json"
      {
        timestamp:        snapshot.timestamp,
        load1:            snapshot.load1,
        mem_used_pct:     snapshot.mem_used_pct,
        disk_used_pct:    snapshot.disk_used_pct,
        uptime_sec:       snapshot.uptime_sec,
        units_total:      snapshot.units_total,
        units_failed:     snapshot.units_failed,
        errors_last_hour: recent_error_count("-1h"),
        units:            snapshot.units,
      }.to_json
    end

    # ## The `/status/history` endpoint
    #
    # Returns the sampled metrics history as JSON. Accepts the usual
    # relative `since` vocabulary (e.g. `?since=-1d`).
    get route_path("status/history") do |env|
      unless Grafito.dashboard_enabled?
        env.response.content_type = "application/json"
        env.response.status_code = 404
        next {error: "Dashboard is disabled"}.to_json
      end

      since_text = optional_query_param(env, "since") || "-1h"
      since = parse_since(since_text)
      if since.nil?
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next {error: "Invalid 'since' parameter: #{since_text}"}.to_json
      end

      points = Grafito.metrics_store.try(&.history(since)) || [] of MetricsStore::MetricPoint
      env.response.content_type = "application/json"
      {points: points}.to_json
    end

    # ## The `/dashboard` endpoint
    #
    # Returns the dashboard HTML fragment for HTMX: health cards, history
    # chart and the unit table. The frontend polls it every 30 seconds.
    # Parameters:
    # * `sort_by` (unit, state, sub, description) and `sort_order`
    #   (asc/desc) control the unit table ordering.
    # * `unit` filters the unit table by name or description.
    # * `since` sets the time window for the history chart and the
    #   error count (e.g. -15m, -1h, -6h, -1d, -7d; default -6h).
    get route_path("dashboard") do |env|
      unless Grafito.dashboard_enabled?
        env.response.status_code = 404
        next "Dashboard is disabled."
      end
      sort_by = optional_query_param(env, "sort_by")
      sort_order = optional_query_param(env, "sort_order")
      unit_filter = optional_query_param(env, "unit")
      since_text = optional_query_param(env, "since")
      unit_flags = Grafito.enable_actions? ? SystemStatus.unit_flags_map : {} of String => SystemStatus::UnitFileFlags
      env.response.content_type = "text/html"
      render_dashboard_fragment(sort_by, sort_order, unit_filter, since_text, unit_flags)
    end

    # ## The `/unit-details` endpoint
    #
    # Returns the service detail fragment for the right sidebar's Detail
    # tab: state pills, recent error count, optional unit actions and a
    # "view logs" call.
    #
    # Example usage:
    # ```text
    # GET /unit-details?name=nginx.service
    # ```
    get route_path("unit-details") do |env|
      unless Grafito.dashboard_enabled?
        env.response.status_code = 404
        next "Dashboard is disabled."
      end

      name = optional_query_param(env, "name")
      if name.nil? || name.empty? || name.starts_with?('-') || !name.matches?(/^[\w.@-]+$/)
        halt env, status_code: 400, response: "Missing or invalid unit name."
      end

      unit_state = SystemStatus.unit_states.find do |unit|
        unit.unit == name || unit.unit == "#{name}.service"
      end
      unless unit_state
        env.response.status_code = 404
        next "Unit '#{HTML.escape(name)}' not found."
      end

      env.response.content_type = "text/html"
      Dashboard.unit_details_fragment(
        unit_state,
        Grafito.enable_actions?,
        unit_error_count(unit_state.unit),
        Grafito.enable_actions? ? SystemStatus.unit_flags_map : {} of String => SystemStatus::UnitFileFlags,
      )
    end

    # ## The `/unit-explain` endpoint
    #
    # `POST /unit-explain?name=<unit>` asks the configured AI provider
    # to explain the unit's current state using its recent journal
    # entries. Returns an HTML fragment for the sidebar. 503 when no AI
    # provider is configured, 404 for unknown units.
    post route_path("unit-explain") do |env|
      unless Grafito.dashboard_enabled?
        env.response.status_code = 404
        next "Dashboard is disabled."
      end

      provider = Grafito.ai_provider
      unless provider
        env.response.content_type = "application/json"
        env.response.status_code = 503
        next {error: "AI features are disabled. Configure a provider key to enable explanations."}.to_json
      end

      name = optional_query_param(env, "name")
      if name.nil? || name.empty? || name.starts_with?('-') || !name.matches?(/^[\w.@-]+$/)
        env.response.content_type = "text/html"
        env.response.status_code = 400
        next "Missing or invalid unit name."
      end

      unit_state = SystemStatus.unit_states.find do |unit|
        unit.unit == name || unit.unit == "#{name}.service"
      end
      unless unit_state
        env.response.content_type = "text/html"
        env.response.status_code = 404
        next "Unit '#{HTML.escape(name)}' not found."
      end

      flags = Grafito.enable_actions? ? SystemStatus.unit_flags_map[name]? : nil
      recent = Journalctl.query(since: "-6h", unit: unit_state.unit, lines: 100) || [] of Journalctl::LogEntry
      errors = recent.count { |entry| entry.priority.to_i? ? entry.priority.to_i <= 3 : false }

      report = String.build do |str|
        str << "Unit: #{unit_state.unit}\n"
        str << "Description: #{unit_state.description}\n"
        str << "Load state: #{unit_state.load_state}\n"
        str << "Active state: #{unit_state.active_state} (#{unit_state.sub_state})\n"
        str << "Unit file state: #{flags.try(&.file_state) || "unknown"}\n"
        str << "Can start: #{flags && !flags.can_start ? "no" : "yes"}\n"
        str << "Errors (priority <= 3) in recent entries: #{errors}\n"
        status_output = SystemStatus.unit_status_output(unit_state.unit)
        if status_output
          str << "\nsystemctl status output:\n"
          str << status_output
          str << "\n" unless status_output.ends_with?("\n")
        else
          str << "\nsystemctl status output: unavailable\n"
        end
        str << "\nRecent journal entries (last 6h, up to #{recent.size} lines):\n"
        recent.each do |entry|
          str << "[#{entry.formatted_timestamp_with_timezone}] [#{entry.formatted_priority}] #{entry.message}\n"
        end
      end

      begin
        request = AI::Request.for_unit_diagnosis(report)
        response = provider.complete(request)
        Log.info { "AI unit explanation generated for #{unit_state.unit} (#{response.content.size} chars)" }
        env.response.content_type = "text/html"
        Dashboard.unit_ai_fragment(response.content)
      rescue ex : Exception
        Log.error(exception: ex) { "AI unit explanation failed for #{unit_state.unit}" }
        env.response.content_type = "text/html"
        # A 200 keeps htmx swapping so the user sees the failure inline.
        Dashboard.unit_ai_fragment("AI request failed: #{ex.message}")
      end
    end

    # ## The unit action endpoint
    #
    # `POST /unit/<name>/<start|stop|restart|enable|disable>` runs
    # systemctl for the named unit. Gated by `--enable-actions`; what an
    # action is actually allowed to do is decided by systemd/polkit for
    # the user Grafito runs as — failures are surfaced verbatim.
    # Returns the refreshed dashboard fragment (or, for `from=panel`
    # requests, the refreshed service panel) so the htmx button updates
    # the view.
    post route_path("unit/:name/:action") do |env|
      unless Grafito.dashboard_enabled? && Grafito.enable_actions? && Grafito.auth_configured?
        env.response.status_code = 403
        next "Unit actions are disabled. Start grafito with --enable-actions and authentication configured (GRAFITO_AUTH_USER/GRAFITO_AUTH_PASS) to allow them."
      end

      unit_name = env.params.url["name"]
      action = env.params.url["action"]

      # Lifecycle and enablement actions; the list is a whitelist too,
      # so anything else is rejected before reaching systemctl.
      unless {"start", "stop", "restart", "enable", "disable"}.includes?(action)
        env.response.status_code = 400
        next "Invalid action '#{HTML.escape(action)}'."
      end

      # Unit names come URL-decoded from the router and go straight into
      # a Process.run argument array (no shell), but reject anything that
      # could be mistaken for a flag.
      if unit_name.empty? || unit_name.starts_with?('-') || !unit_name.matches?(/^[\w.@-]+$/)
        env.response.status_code = 400
        next "Invalid unit name."
      end

      known_units = SystemStatus.unit_states.map(&.unit)
      full_unit = known_units.includes?(unit_name) ? unit_name : "#{unit_name}.service"
      unless known_units.includes?(full_unit)
        env.response.status_code = 404
        next "Unit '#{HTML.escape(unit_name)}' not found."
      end

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      result = Process.run(
        "systemctl",
        args: Journalctl.user_flags + [action, full_unit],
        output: stdout,
        error: stderr,
      )
      unless result.normal_exit?
        # Authorization and other failures come from systemd itself;
        # surface them instead of a generic message. Panel requests get
        # an error fragment swapped into the sidebar (htmx ignores error
        # statuses, so a success status is needed to show it).
        from_panel = optional_query_param(env, "from") == "panel"
        message = stderr.to_s.strip
        message = "systemctl #{action} #{full_unit} failed." if message.empty?
        Log.error { "systemctl #{action} #{full_unit} failed: #{message[0..200]}" }
        if from_panel
          env.response.status_code = 200
          env.response.content_type = "text/html"
          next Dashboard.action_error_fragment(action, full_unit, message)
        end
        env.response.status_code = 500
        next HTML.escape(message)
      end

      Log.info { "systemctl #{action} #{full_unit} succeeded" }
      env.response.content_type = "text/html"
      # Actions triggered from the sidebar refresh the panel instead of
      # the whole dashboard; the dashboard catches up on its next poll.
      if optional_query_param(env, "from") == "panel"
        refreshed = SystemStatus.unit_states.find { |unit| unit.unit == full_unit }
        if refreshed
          next Dashboard.unit_details_fragment(
            refreshed,
            Grafito.enable_actions?,
            unit_error_count(full_unit),
            Grafito.enable_actions? ? SystemStatus.unit_flags_map : {} of String => SystemStatus::UnitFileFlags,
          )
        end
      end
      render_dashboard_fragment
    end
  end # register_routes

  # Counts journal entries at priority <= 3 (error or worse) for one
  # unit since the given relative time. Bounded like the dashboard's
  # global error count.
  private def self.unit_error_count(unit_name : String, since : String = "-1h") : Int32
    return 0 unless Grafito.dashboard_enabled?
    logs = Journalctl.query(since: since, priority: "3", unit: unit_name, lines: 500)
    logs ? logs.size : 0
  end

  # Returns the dashboard HTML fragment used by both GET /dashboard and
  # the unit-action POST responses. Invalid since values fall back to
  # the default 6-hour window.
  private def self.render_dashboard_fragment(
    sort_by : String? = nil,
    sort_order : String? = nil,
    unit_filter : String? = nil,
    since_text : String? = nil,
    unit_flags : Hash(String, SystemStatus::UnitFileFlags) = {} of String => SystemStatus::UnitFileFlags,
  ) : String
    snapshot = SystemStatus.snapshot
    since_time = parse_since(since_text.to_s) || DEFAULT_DASHBOARD_SINCE
    history = Grafito.metrics_store.try(&.history(since_time)) || [] of MetricsStore::MetricPoint
    errors = recent_error_count(since_text.presence || "-6h")
    Dashboard.render_html(
      snapshot,
      history,
      errors,
      Grafito.enable_actions?,
      sort_by,
      sort_order,
      unit_filter,
      since_text,
      unit_flags,
    )
  end

  # Counts journal entries at priority <= 3 (error or worse) since the
  # given relative time. Bounded to 500 lines to keep dashboard refreshes
  # cheap; the count is a signal, not an audit.
  private def self.recent_error_count(since : String) : Int32
    return 0 unless Grafito.dashboard_enabled?
    logs = Journalctl.query(since: since, priority: "3", lines: 500)
    logs ? logs.size : 0
  end

  # Parses the same relative time vocabulary the logs endpoint uses
  # (-15m, -1h, -1d, -1M, -1y) into a Time.
  private def self.parse_since(since_text : String) : Time?
    match = since_text.strip.match(/^-?(\d+)([mhdMy])$/)
    return unless match

    amount = match[1].to_i
    span = case match[2]
           when "m" then Time::Span.new(minutes: amount)
           when "h" then Time::Span.new(hours: amount)
           when "d" then Time::Span.new(days: amount)
           when "M" then Time::Span.new(days: amount * 30)
           else          Time::Span.new(days: amount * 365) # "y"
           end
    Time.utc - span
  end
end
