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
require "./compose_status"
require "./compose_dashboard"
require "./compose_jobs"
require "./process_status"
require "./process_dashboard"
require "./homepage_config"
require "./homepage"

{% if flag?(:fake_journal) %}
  require "./fake_compose_data"
  require "./fake_homepage_data"
{% end %}

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

  # Compose view - when enabled, the /compose* routes are served and
  # the Compose toggle appears in the frontend.
  class_property? compose_enabled : Bool = true

  # Process view - when enabled, the /processes routes are served and
  # the Processes toggle appears in the frontend.
  class_property? processes_enabled : Bool = true

  # Homepage view - when enabled, the /homepage route is served and
  # the Homepage toggle appears in the frontend.
  class_property? homepage_enabled : Bool = true

  # Where the homepage view reads its service list from.
  class_property homepage_config_path : String = "/etc/grafito/homepage.yml"

  # Metrics sampler, nil when the dashboard is disabled (and in specs).
  class_property metrics_store : MetricsStore? = nil

  # When enabled, the dashboard's unit table offers start/stop/restart
  # buttons restricted to the --units whitelist.
  class_property? enable_actions : Bool = false

  # Helper to build route paths with proper base path handling.
  # Public so each view module can delegate its own route_path to it.
  def self.route_path(path : String) : String
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

    # ## Views
    #
    # Each view owns its endpoints in its own module; adding a view
    # means one module with a `register_routes` method, a require, a
    # call here, and a small frontend addition. See the VIEWS registry
    # in src/assets/index.html for the frontend side.
    Dashboard.register_routes
    ComposeDashboard.register_routes
    ProcessDashboard.register_routes
    HomepageDashboard.register_routes
  end # register_routes
end
