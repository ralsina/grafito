# # Compose dashboard
#
# The compose view is an HTMX fragment like the systemd dashboard: the
# frontend polls `GET /compose` every 30 seconds and swaps it into
# `#compose-view`. This module renders that fragment: summary cards and
# one section per stack, each with stack-level action buttons (up,
# stop, restart, image update, YAML view) and a service table.
#
# Stack-level actions take a while and stream their progress, so their
# buttons target a per-stack output area instead of the table itself;
# `ComposeJobs` runs the command and this module renders its polling
# fragment. Service actions are quick and refresh the whole view (or
# the sidebar panel when triggered from there), exactly like the unit
# actions in [dashboard.cr](dashboard.cr.html).

require "html_builder"
require "log"

require "./app_store"
require "./compose_status"
require "./compose_jobs"
require "./process_status"

{% if flag?(:demo_mode) %}
  require "./fake_appstore_data"
  require "./fake_compose_data"
{% end %}

module ComposeDashboard
  extend self

  Log = ::Log.for(self)

  # Renders the compose view fragment. `enable_actions` gates every
  # state-changing button, mirroring the dashboard's flag.
  def render_html(
    stacks : Array(ComposeStatus::Stack),
    enable_actions : Bool = false,
  ) : String
    installed_by_project = installed_apps_by_project
    HTML.build do
      html compose_toolbar(enable_actions)

      div(class: "dashboard-grid") do
        html card("Stacks", stacks.size.to_s)
        html card("Services", total_services(stacks).to_s)
        html card("Running", running_services(stacks).to_s)
        html card("Unhealthy", unhealthy_services(stacks).to_s, warn: unhealthy_services(stacks) > 0)
      end

      if stacks.empty?
        div(class: "compose-empty") do
          text "No Docker Compose stacks found. Is docker installed and running?"
        end
      else
        # One container for all stacks: CSS turns it into two columns on
        # wide viewports.
        div(class: "compose-stacks") do
          stacks.each do |compose_stack|
            html stack_section(compose_stack, enable_actions, installed_by_project[compose_stack.name]?)
          end
        end
      end
    end
  end

  # The view-level toolbar: currently just the app store entry point,
  # shown when actions are allowed (the store is useless without them).
  private def compose_toolbar(enable_actions : Bool) : String
    return "" unless enable_actions && Grafito.apps_enabled?
    HTML.build do
      div(class: "compose-toolbar") do
        button(
          class: "compose-addapp",
          title: "Install an app from the app store",
          "hx-get": "#{base}/compose-appstore",
          "hx-target": "#panel-detail-content",
          "hx-swap": "innerHTML",
          "hx-indicator": "#loading-spinner",
          "hx-on:htmx:before-request": "panelSpinner('panel-detail-content')",
          "hx-on:htmx:after-request": "if(event.detail.successful){showLogPanel('detail')}else{panelError('panel-detail-content',event.detail.xhr.status);showLogPanel('detail')}",
        ) do
          span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
            text "add_circle"
          end
          text " Add app"
        end
      end
    end
  end

  # Installed store apps indexed by compose project name. Demo builds
  # have no on-disk installs; their fixture badge comes from the fake
  # data module instead.
  private def installed_apps_by_project : Hash(String, AppStore::InstalledApp)
    {% if flag?(:demo_mode) %}
      FakeAppStore.installed.index_by(&.project_name)
    {% else %}
      AppStore.installed(Grafito.data_dir).index_by(&.project_name)
    {% end %}
  end

  private def total_services(stacks : Array(ComposeStatus::Stack)) : Int32
    stacks.sum(&.services.size)
  end

  private def running_services(stacks : Array(ComposeStatus::Stack)) : Int32
    stacks.sum(&.running_count)
  end

  private def unhealthy_services(stacks : Array(ComposeStatus::Stack)) : Int32
    stacks.sum(&.unhealthy_count)
  end

  # One stack: header with status (and the store-app badge, when the
  # stack was installed from an app store), actions, optional job
  # output area, then the service table.
  # ameba:disable Metrics/CyclomaticComplexity
  private def stack_section(
    compose_stack : ComposeStatus::Stack,
    enable_actions : Bool,
    installed : AppStore::InstalledApp? = nil,
  ) : String
    update_version = update_available_version(installed)
    badge = installed ? app_badge(installed, update_version) : ""
    store_buttons = (enable_actions && installed) ? store_action_buttons(compose_stack, installed, update_version) : ""
    HTML.build do
      div(class: "compose-stack") do
        div(class: "compose-stack-header") do
          tag("h3") do
            text compose_stack.name
            html status_pill(compose_stack.status.empty? ? "unknown" : compose_stack.status)
            html badge
          end
          div(class: "compose-stack-actions") do
            if enable_actions && compose_stack.actionable?
              html stack_action_button(compose_stack, "up", "play_arrow", "Start stack (up -d)")
              html stack_action_button(compose_stack, "stop", "stop", "Stop stack")
              html stack_action_button(compose_stack, "restart", "restart_alt", "Restart stack")
              html stack_action_button(compose_stack, "update", "update", "Pull images and up -d")
            end
            html store_buttons
            if compose_stack.actionable?
              button(
                class: "round-button",
                title: "View compose.yaml for #{compose_stack.name}",
                "hx-get": yaml_url(compose_stack.name),
                "hx-target": "#panel-detail-content",
                "hx-swap": "innerHTML",
                "hx-indicator": "#loading-spinner",
              ) do
                span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
                  text "description"
                end
              end
            end
          end
        end

        div(id: "compose-output-area-#{compose_stack.name}") { }

        table(class: "striped dashboard-units") do
          thead do
            tr do
              th { text "State" }
              th { text "Health" }
              th { text "Service" }
              th { text "Image" }
              th { text "Ports" }
              if enable_actions
                th { text "Actions" }
              end
            end
          end
          tbody do
            if compose_stack.services.empty?
              tr do
                td(colspan: enable_actions ? "6" : "5", style: "text-align: center; padding: 1em;") do
                  text "No containers found for this stack."
                end
              end
            else
              compose_stack.services.each do |compose_service|
                html service_row(compose_service, enable_actions)
              end
            end
          end
        end
      end
    end
  end

  # One service row. Clicking it opens the sidebar Detail tab; the
  # action buttons stop propagation so they don't also trigger the
  # row's htmx request.
  private def service_row(compose_service : ComposeStatus::Service, enable_actions : Bool) : String
    row_class = "du-state-#{compose_service.state}"
    row_class = "#{row_class} dashboard-unit-failed" if compose_service.unhealthy?
    HTML.build do
      tr(
        class: row_class,
        title: "Show details for #{compose_service.service}",
        "hx-get": details_url(compose_service.stack, compose_service.service),
        "hx-target": "#panel-detail-content",
        "hx-swap": "innerHTML",
        "hx-on:htmx:before-request": "panelSpinner('panel-detail-content')",
        "hx-on:htmx:after-request": "if(event.detail.successful){showLogPanel('detail')}else{panelError('panel-detail-content',event.detail.xhr.status);showLogPanel('detail')}",
      ) do
        td(class: "dashboard-state-cell") do
          html state_pill(compose_service.state)
        end
        td(class: "dashboard-sub-cell") do
          html health_pill(compose_service.health)
        end
        td(title: compose_service.container) do
          text compose_service.service
        end
        td(title: compose_service.image) do
          text compose_service.image
        end
        td do
          text compose_service.ports
        end
        if enable_actions
          td(class: "dashboard-action-cell") do
            service_actions(compose_service).each do |action_item|
              html service_action_button(compose_service, action_item[:action], action_item[:icon], false)
            end
          end
        end
      end
    end
  end

  # State-appropriate actions for one service, like the dashboard's
  # lifecycle_actions: start stopped services, stop/restart running
  # ones.
  private def service_actions(compose_service : ComposeStatus::Service) : Array(NamedTuple(action: String, icon: String))
    actions = [] of NamedTuple(action: String, icon: String)
    case compose_service.state
    when "running", "restarting"
      actions << {action: "stop", icon: "stop"}
      actions << {action: "restart", icon: "restart_alt"}
    else
      actions << {action: "start", icon: "play_arrow"}
    end
    actions
  end

  # Icon-only button for a service action. `from_panel` refreshes the
  # sidebar panel instead of the whole view.
  private def service_action_button(
    compose_service : ComposeStatus::Service,
    action : String,
    icon : String,
    from_panel : Bool,
  ) : String
    HTML.build do
      button(
        class: "round-button",
        title: "#{action[0].upcase}#{action[1..]} #{compose_service.service}",
        "aria-label": "#{action[0].upcase}#{action[1..]} #{compose_service.service}",
        "hx-post": "#{service_action_url(compose_service.stack, compose_service.service, action)}#{from_panel ? "?from=panel" : ""}",
        "hx-target": from_panel ? "#panel-detail-content" : "#compose-view",
        "hx-swap": "innerHTML",
        "hx-confirm": "#{action[0].upcase}#{action[1..]} service #{compose_service.service} of stack #{compose_service.stack}?",
        "hx-indicator": "#loading-spinner",
        onclick: "event.stopPropagation()",
      ) do
        span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
          text icon
        end
      end
    end
  end

  # Icon-only button for a stack-level action. These start background
  # jobs; the POST answers with the job's polling fragment, swapped
  # into the stack's output area.
  private def stack_action_button(
    compose_stack : ComposeStatus::Stack,
    action : String,
    icon : String,
    description : String,
  ) : String
    HTML.build do
      button(
        class: "round-button",
        title: description,
        "aria-label": description,
        "hx-post": stack_action_url(compose_stack.name, action),
        "hx-target": "#compose-output-area-#{compose_stack.name}",
        "hx-swap": "innerHTML",
        "hx-confirm": "#{action[0].upcase}#{action[1..]} stack #{compose_stack.name}?",
        "hx-indicator": "#loading-spinner",
      ) do
        span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
          text icon
        end
      end
    end
  end

  # The newest version the synced store offers for an installed app,
  # or nil when the app is up to date (or the store cache has no
  # answer). Demo builds have no store cache; the fake data module
  # reports the fixture install as updatable so the UI is exercised.
  private def update_available_version(installed : AppStore::InstalledApp?) : String?
    return unless installed
    {% if flag?(:demo_mode) %}
      FakeAppStore.update_available(installed)
    {% else %}
      store_app = AppStore.store_app_for(Grafito.data_dir, installed)
      return nil unless store_app
      store_app.tipi_version > installed.tipi_version ? store_app.version : nil
    {% end %}
  end

  # The "installed from the app store" badge shown next to a stack's
  # status pill.
  private def app_badge(installed : AppStore::InstalledApp, update_version : String?) : String
    HTML.build do
      span(class: "tag tag-info appstore-badge", title: "Installed from the #{installed.store} app store") do
        text "#{installed.name} #{installed.version}"
      end
      if update_version
        span(class: "tag tag-warn appstore-badge", title: "The app store offers a newer package") do
          text "update: #{update_version}"
        end
      end
    end
  end

  # Update/uninstall buttons for an installed app's stack header,
  # answered by the app store endpoints with the same job-output
  # fragments as the stack actions.
  private def store_action_buttons(
    compose_stack : ComposeStatus::Stack,
    installed : AppStore::InstalledApp,
    update_version : String?,
  ) : String
    HTML.build do
      if update_version
        button(
          class: "round-button",
          title: "Update app from the store",
          "aria-label": "Update app from the store",
          "hx-post": "#{base}/compose-appstore-update",
          "hx-vals": %({"stack": "#{compose_stack.name}"}),
          "hx-target": "#compose-output-area-#{compose_stack.name}",
          "hx-swap": "innerHTML",
          "hx-confirm": "Update #{installed.name} from the app store?",
          "hx-indicator": "#loading-spinner",
        ) do
          span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
            text "cloud_download"
          end
        end
      end
      button(
        class: "round-button",
        title: "Uninstall app (containers removed, data kept)",
        "aria-label": "Uninstall app (containers removed, data kept)",
        "hx-post": "#{base}/compose-appstore-uninstall",
        "hx-vals": %({"stack": "#{compose_stack.name}"}),
        "hx-target": "#compose-output-area-#{compose_stack.name}",
        "hx-swap": "innerHTML",
        "hx-confirm": "Uninstall #{installed.name}? Containers are removed; app data is kept.",
        "hx-indicator": "#loading-spinner",
      ) do
        span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
          text "delete"
        end
      end
    end
  end

  # The job output fragment, swapped into the stack's output area and
  # re-polled every second by replacing itself, until the job is done.
  # While a job is running, the fragment also carries
  # `data-job-running`, which the page's 30s auto-refresh trigger
  # checks so a poll doesn't wipe the output mid-run.
  def output_fragment(job : ComposeJobs::Job, anchor_id : String) : String
    snapshot = job.snapshot
    running = snapshot.running
    status_label = if running
                     "Running"
                   else
                     snapshot.exit_code == 0 ? "Done" : "Failed (exit #{snapshot.exit_code})"
                   end
    status_class = running ? "tag-warn" : (snapshot.exit_code == 0 ? "tag-ok" : "tag-err")
    poll_attributes = {} of String => String
    if running
      poll_attributes["hx-get"] = output_url(job.id, anchor_id)
      poll_attributes["hx-trigger"] = "every 1s"
      poll_attributes["hx-swap"] = "outerHTML"
      # Explicit target: without it htmx inherits hx-target="this" from
      # the #compose-view ancestor and the poll replaces the view.
      poll_attributes["hx-target"] = "this"
    end
    HTML.build do
      tag("div", poll_attributes.merge!({
        "id"               => anchor_id,
        "class"            => "compose-output",
        "data-job-running" => running ? "true" : "false",
      })) do
        span(class: "tag #{status_class}") { text status_label }
        tag("pre", class: "compose-output-lines") do
          text snapshot.lines.join("\n")
        end
      end
    end
  end

  # The sidebar Detail-tab fragment for one service: pills, identity
  # info, actions, a pollable log tail, and the stack's YAML.
  # Compacts docker's Ports string ("0.0.0.0:8887-8888->8887-8888/tcp,
  # [::]:8887-8888->8887-8888/tcp") into the unique host-side mappings
  # ("8887-8888->8887-8888/tcp"), dropping the repeated IPv4/IPv6
  # listen addresses.
  def self.compact_ports(raw : String) : String
    seen = [] of String
    raw.split(", ").each do |part|
      compacted = part
      if idx = part.index("->")
        host = part[0...idx]
        compacted = "#{host.sub(/^.*:/, "")}#{part[idx..]}"
      end
      seen << compacted unless seen.includes?(compacted)
    end
    seen.join(", ")
  end

  def service_details_fragment(
    compose_service : ComposeStatus::Service,
    enable_actions : Bool = false,
    member_processes : Array(ProcessStatus::ProcessInfo) = [] of ProcessStatus::ProcessInfo,
  ) : String
    HTML.build do
      div(class: "service-panel") do
        tag("h4") do
          text "#{compose_service.stack} / #{compose_service.service}"
        end
        div(class: "service-panel-pills") do
          html state_pill(compose_service.state)
          html health_pill(compose_service.health)
        end

        div(class: "service-panel-info") do
          div do
            span(class: "stat-label") { text "Container" }
            span { text compose_service.container }
          end
          div do
            span(class: "stat-label") { text "Image" }
            span { text compose_service.image }
          end
          div do
            span(class: "stat-label") { text "Ports" }
            span { text compose_service.ports.empty? ? "—" : compact_ports(compose_service.ports) }
          end
          div do
            span(class: "stat-label") { text "Status" }
            span { text compose_service.status_text }
          end
        end

        if enable_actions
          div(class: "service-panel-actions") do
            service_actions(compose_service).each do |action_item|
              html service_action_button(compose_service, action_item[:action], action_item[:icon], true)
            end
            span(class: "service-panel-hint") { text "docker compose actions" }
          end
        end

        unless member_processes.empty?
          div(class: "service-panel-members") do
            span(class: "stat-label") { text "Processes" }
            member_processes.each do |process_info|
              div(class: "service-member-row") do
                span(class: "service-member-pid") { text "PID #{process_info.pid}" }
                span(class: "service-member-cmd", title: process_info.command) { text process_info.command }
                span(class: "tag tag-muted") { text "CPU #{process_info.cpu_pct.round(1)}%" }
              end
            end
            span(class: "service-panel-hint") { text "live from the process monitor" }
          end
        end

        div(class: "service-panel-ai") do
          button(
            {
              "class":        "service-panel-explain",
              "title":        "Show the recent log tail for this service",
              "hx-get":       logs_url(compose_service.stack, compose_service.service),
              "hx-target":    "#panel-detail-content",
              "hx-swap":      "innerHTML",
              "hx-indicator": "#loading-spinner",
            }
          ) do
            span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
              text "article"
            end
            text " Service logs"
          end
        end
      end
    end
  end

  # A read-only compose.yaml for one stack, shown in the Detail tab.
  def yaml_fragment(stack_name : String, content : String) : String
    HTML.build do
      div(class: "service-panel") do
        tag("h4") do
          text stack_name
        end
        div(class: "service-panel-pills") do
          span(class: "tag tag-info") { text "compose.yaml" }
        end
        tag("pre", class: "compose-yaml") do
          text content
        end
      end
    end
  end

  # The service log tail fragment. Polls itself every 5 seconds so the
  # tail keeps moving while the panel is open; the swap replaces the
  # inner content of #compose-logs-content, and the poll trigger lives
  # on the fragment root so it stops once the panel content changes.
  def logs_fragment(stack_name : String, service_name : String, content : String) : String
    HTML.build do
      tag("div", {
        "class":      "compose-logs",
        "hx-get":     logs_url(stack_name, service_name),
        "hx-trigger": "every 5s",
        "hx-target":  "this",
        "hx-swap":    "innerHTML",
      }) do
        tag("pre", class: "compose-output-lines") do
          text content.empty? ? "(no logs)" : content
        end
      end
    end
  end

  # Renders a failed action as an error block for the service panel,
  # like the dashboard does.
  def action_error_fragment(action : String, target : String, message : String) : String
    HTML.build do
      div(class: "service-panel service-panel-error") do
        tag("h4") do
          text "#{action[0].upcase}#{action[1..]} failed: #{target}"
        end
        tag("pre", class: "service-panel-error-message") do
          text message
        end
      end
    end
  end

  # One summary card, reusing the dashboard's `.stat` styling.
  private def card(label : String, value : String, warn : Bool = false) : String
    HTML.build do
      div(class: "stat") do
        span(class: "stat-label") { text label }
        span(class: warn ? "stat-value stat-error" : "stat-value") do
          text value
        end
      end
    end
  end

  # Container state pill, matching the dashboard's tag colors.
  private def state_pill(value : String) : String
    color = case value
            when "running"              then "ok"
            when "restarting", "paused" then "warn"
            when "removing", "dead"     then "err"
            when "created"              then "info"
            else                             "debug" # exited
            end
    HTML.build do
      span(class: "tag tag-#{color}") do
        text value
      end
    end
  end

  # Healthcheck verdict pill; an empty verdict means no healthcheck.
  private def health_pill(value : String) : String
    return HTML.build { span(class: "tag tag-muted") { text "—" } } if value.empty?
    color = case value
            when "healthy"  then "ok"
            when "starting" then "warn"
            else                 "err" # unhealthy
            end
    HTML.build do
      span(class: "tag tag-#{color}") do
        text value
      end
    end
  end

  # Stack status text from `compose ls` (e.g. "running(3)", "exited(1)")
  # rendered as a pill; free-form statuses fall back to muted.
  private def status_pill(value : String) : String
    color = if value.starts_with?("running")
              "ok"
            elsif value.starts_with?("exited") || value.starts_with?("dead")
              "debug"
            elsif value.empty?
              "muted"
            else
              "warn"
            end
    HTML.build do
      span(class: "tag tag-#{color}") do
        text value
      end
    end
  end

  private def details_url(stack_name : String, service_name : String) : String
    "#{base}/compose-details?stack=#{URI.encode_path(stack_name)}&service=#{URI.encode_path(service_name)}"
  end

  private def logs_url(stack_name : String, service_name : String) : String
    "#{base}/compose-logs?stack=#{URI.encode_path(stack_name)}&service=#{URI.encode_path(service_name)}"
  end

  private def yaml_url(stack_name : String) : String
    "#{base}/compose-yaml?stack=#{URI.encode_path(stack_name)}"
  end

  private def stack_action_url(stack_name : String, action : String) : String
    "#{base}/compose-stack/#{URI.encode_path(stack_name)}/#{action}"
  end

  private def service_action_url(stack_name : String, service_name : String, action : String) : String
    "#{base}/compose-service/#{URI.encode_path(stack_name)}/#{URI.encode_path(service_name)}/#{action}"
  end

  # The job output poll URL carries the anchor id, so every polled
  # response keeps the same DOM id and replaces exactly itself.
  private def output_url(job_id : String, anchor_id : String) : String
    "#{base}/compose-output/#{job_id}?anchor=#{URI.encode_www_form(anchor_id)}"
  end

  # Base path prefix, empty for the common "/" deployment.
  private def base : String
    Grafito.base_path == "/" ? "" : Grafito.base_path
  end

  # Route helpers of the enclosing Grafito module, re-exposed here so
  # the route bodies below can use them verbatim.
  private def self.optional_query_param(env : HTTP::Server::Context, key : String) : String?
    Grafito.optional_query_param(env, key)
  end

  private def self.route_path(path : String) : String
    Grafito.route_path(path)
  end

  # ## Routes
  #
  # The compose view owns its endpoints (fragment, service details,
  # YAML, logs, stack/service actions and the job output poller).
  def self.register_routes
    # ## The compose view endpoints
    #
    # A third view, next to the log viewer and the dashboard: the
    # Docker Compose stacks on this machine, their services, and
    # (gated by --enable-actions like unit actions) lifecycle buttons.
    # `GET /compose` returns the HTMX fragment the frontend polls;
    # the other endpoints feed the sidebar Detail tab and the action
    # buttons.
    get route_path("compose") do |env|
      unless Grafito.compose_enabled?
        env.response.status_code = 404
        next "Compose view is disabled."
      end
      env.response.content_type = "text/html"
      ComposeDashboard.render_html(ComposeStatus.stacks, Grafito.enable_actions?)
    end

    # Sidebar Detail-tab fragment for one service of one stack.
    get route_path("compose-details") do |env|
      unless Grafito.compose_enabled?
        env.response.status_code = 404
        next "Compose view is disabled."
      end
      stack_name = optional_query_param(env, "stack")
      service_name = optional_query_param(env, "service")
      unless valid_compose_name?(stack_name) && valid_compose_name?(service_name)
        halt env, status_code: 400, response: "Missing or invalid stack/service name."
      end

      compose_service = ComposeStatus.find_service(stack_name.to_s, service_name.to_s)
      unless compose_service
        env.response.status_code = 404
        next "Service '#{HTML.escape(service_name.to_s)}' of stack '#{HTML.escape(stack_name.to_s)}' not found."
      end
      env.response.content_type = "text/html"
      ComposeDashboard.service_details_fragment(
        compose_service,
        Grafito.enable_actions?,
        ProcessStatus.processes_for_compose_service(stack_name.to_s, service_name.to_s),
      )
    end

    # Read-only compose.yaml view for one stack, shown in the Detail
    # tab. The path comes from the `docker compose ls` whitelist, so
    # the endpoint can only read files docker itself reported.
    get route_path("compose-yaml") do |env|
      unless Grafito.compose_enabled?
        env.response.status_code = 404
        next "Compose view is disabled."
      end
      stack_name = optional_query_param(env, "stack")
      unless valid_compose_name?(stack_name)
        halt env, status_code: 400, response: "Missing or invalid stack name."
      end

      compose_stack = ComposeStatus.find_stack(stack_name.to_s)
      unless compose_stack
        env.response.status_code = 404
        next "Stack '#{HTML.escape(stack_name.to_s)}' not found."
      end
      unless compose_stack.actionable?
        env.response.content_type = "text/html"
        next ComposeDashboard.action_error_fragment("View", compose_stack.name, "The compose file for this stack is not known (config files missing).")
      end

      content = compose_yaml_content(compose_stack)
      env.response.content_type = "text/html"
      ComposeDashboard.yaml_fragment(compose_stack.name, content)
    end

    # Recent log tail for one service, via `docker compose logs`.
    # Pollable: the fragment re-requests itself every few seconds
    # while the panel is open.
    get route_path("compose-logs") do |env|
      unless Grafito.compose_enabled?
        env.response.status_code = 404
        next "Compose view is disabled."
      end
      stack_name = optional_query_param(env, "stack")
      service_name = optional_query_param(env, "service")
      tail = optional_query_param(env, "tail").try(&.to_i?) || 200
      tail = tail.clamp(1, 5000)
      unless valid_compose_name?(stack_name) && valid_compose_name?(service_name)
        halt env, status_code: 400, response: "Missing or invalid stack/service name."
      end

      compose_stack = ComposeStatus.find_stack(stack_name.to_s)
      unless compose_stack
        env.response.status_code = 404
        next "Stack '#{HTML.escape(stack_name.to_s)}' not found."
      end
      compose_service = compose_stack.services.find(&.service.==(service_name))
      unless compose_service
        env.response.status_code = 404
        next "Service '#{HTML.escape(service_name.to_s)}' of stack '#{HTML.escape(stack_name.to_s)}' not found."
      end

      args = compose_command_prefix(compose_stack) + ["logs", "--no-color", "--tail", tail.to_s, compose_service.service]
      content = ComposeStatus.run_docker(args)
      env.response.content_type = "text/html"
      ComposeDashboard.logs_fragment(compose_service.stack, compose_service.service, content)
    end

    # Stack-level actions (up, stop, restart, image update). These run
    # as background jobs so their output streams into the stack's
    # output area; the POST answers with the job's polling fragment.
    post route_path("compose-stack/:stack/:action") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless compose_actions_allowed?
        env.response.status_code = 403
        next "Compose actions are disabled. Start grafito with --enable-actions and authentication configured (GRAFITO_AUTH_USER/GRAFITO_AUTH_PASS) to allow them."
      end

      stack_name = env.params.url["stack"]
      action = env.params.url["action"]
      unless {"up", "stop", "restart", "update"}.includes?(action)
        env.response.status_code = 400
        next "Invalid action '#{HTML.escape(action)}'."
      end
      unless valid_compose_name?(stack_name)
        env.response.status_code = 400
        next "Invalid stack name."
      end

      compose_stack = ComposeStatus.find_stack(stack_name)
      unless compose_stack
        env.response.status_code = 404
        next "Stack '#{HTML.escape(stack_name)}' not found."
      end
      unless compose_stack.actionable?
        env.response.status_code = 409
        next "The compose file for stack '#{HTML.escape(stack_name)}' is not known; cannot operate on it."
      end

      {% if flag?(:demo_mode) %}
        # Demo build: the fake world flips state right away, then the
        # job replays plausible output. No docker runs anywhere.
        FakeComposeData.apply_stack_action(stack_name, action)
      {% end %}
      commands = case action
                 when "up"
                   [compose_command_prefix(compose_stack) + ["up", "-d"]]
                 when "stop"
                   [compose_command_prefix(compose_stack) + ["stop"]]
                 when "restart"
                   [compose_command_prefix(compose_stack) + ["restart"]]
                 else # update: pull images, then bring the stack back up
                   [
                     compose_command_prefix(compose_stack) + ["pull"],
                     compose_command_prefix(compose_stack) + ["up", "-d"],
                   ]
                 end
      job_id = ComposeJobs.start("#{action} #{compose_stack.name}", commands)
      env.response.content_type = "text/html"
      job = ComposeJobs.find(job_id)
      if job
        ComposeDashboard.output_fragment(job, "compose-output-#{compose_stack.name}")
      else
        env.response.status_code = 500
        "Failed to start compose job."
      end
    end

    # Service-level actions (start, stop, restart), quick enough to run
    # synchronously like the unit actions. Answers with the refreshed
    # view, or the refreshed panel for from=panel requests.
    post route_path("compose-service/:stack/:service/:action") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless compose_actions_allowed?
        env.response.status_code = 403
        next "Compose actions are disabled. Start grafito with --enable-actions and authentication configured (GRAFITO_AUTH_USER/GRAFITO_AUTH_PASS) to allow them."
      end

      stack_name = env.params.url["stack"]
      service_name = env.params.url["service"]
      action = env.params.url["action"]
      unless {"start", "stop", "restart"}.includes?(action)
        env.response.status_code = 400
        next "Invalid action '#{HTML.escape(action)}'."
      end
      unless valid_compose_name?(stack_name) && valid_compose_name?(service_name)
        env.response.status_code = 400
        next "Invalid stack or service name."
      end

      compose_service = ComposeStatus.find_service(stack_name, service_name)
      unless compose_service
        env.response.status_code = 404
        next "Service '#{HTML.escape(service_name)}' of stack '#{HTML.escape(stack_name)}' not found."
      end
      compose_stack = ComposeStatus.find_stack(stack_name)
      unless compose_stack
        env.response.status_code = 404
        next "Stack '#{HTML.escape(stack_name)}' not found."
      end
      unless compose_stack.actionable?
        env.response.status_code = 409
        next "The compose file for stack '#{HTML.escape(stack_name)}' is not known; cannot operate on it."
      end

      {% if flag?(:demo_mode) %}
        # Demo build: simulate the compose action against the fake
        # stack state; no docker runs anywhere. Same response shapes as
        # the real path below.
        if FakeComposeData.apply_service_action(stack_name, service_name, action) &&
           (refreshed = ComposeStatus.find_service(stack_name, service_name))
          Log.info { "Demo mode: docker compose #{action} #{service_name} (stack #{stack_name}) simulated" }
          env.response.content_type = "text/html"
          if optional_query_param(env, "from") == "panel"
            members = ProcessStatus.processes_for_compose_service(refreshed.stack, refreshed.service)
            next ComposeDashboard.service_details_fragment(refreshed, Grafito.enable_actions?, members)
          end
          next ComposeDashboard.render_html(ComposeStatus.stacks, Grafito.enable_actions?)
        end
        env.response.status_code = 500
        next "Failed to simulate the action."
      {% else %}
        args = compose_command_prefix(compose_stack) + [action, compose_service.service]
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        result = Process.run(args[0], args: args[1..], output: stdout, error: stderr)
        unless result.success?
          from_panel = optional_query_param(env, "from") == "panel"
          message = stderr.to_s.strip
          message = "docker compose #{action} #{compose_service.service} failed." if message.empty?
          Log.error { "docker compose #{action} #{compose_service.service} failed: #{message[0..200]}" }
          if from_panel
            env.response.status_code = 200
            env.response.content_type = "text/html"
            next ComposeDashboard.action_error_fragment(action, "#{compose_service.stack}/#{compose_service.service}", message)
          end
          env.response.status_code = 500
          next HTML.escape(message)
        end

        Log.info { "docker compose #{action} #{compose_service.service} (stack #{compose_service.stack}) succeeded" }
        env.response.content_type = "text/html"
        if optional_query_param(env, "from") == "panel"
          refreshed = ComposeStatus.find_service(stack_name, service_name)
          if refreshed
            members = ProcessStatus.processes_for_compose_service(refreshed.stack, refreshed.service)
            next ComposeDashboard.service_details_fragment(refreshed, Grafito.enable_actions?, members)
          end
        end
        ComposeDashboard.render_html(ComposeStatus.stacks, Grafito.enable_actions?)
      {% end %}
    end

    # Polling fragment for a compose job's output. The anchor id keeps
    # the output area's DOM id stable across polls so htmx keeps
    # replacing the same node until the job finishes.
    get route_path("compose-output/:job") do |env|
      unless Grafito.compose_enabled?
        env.response.status_code = 404
        next "Compose view is disabled."
      end
      job = ComposeJobs.find(env.params.url["job"])
      unless job
        env.response.status_code = 404
        next "Unknown compose job."
      end
      anchor = optional_query_param(env, "anchor")
      anchor = "compose-output" if anchor.nil? || anchor.empty? || !anchor.matches?(/^[\w-]+$/)
      env.response.content_type = "text/html"
      ComposeDashboard.output_fragment(job, anchor)
    end
  end

  # The compose.yaml text for one stack. Demo builds have no real files
  # behind the fake stacks, so they serve generated content instead.
  private def self.compose_yaml_content(compose_stack : ComposeStatus::Stack) : String
    {% if flag?(:demo_mode) %}
      FakeComposeData.compose_yaml(compose_stack.name)
    {% else %}
      begin
        File.read(compose_stack.config_files.first)
      rescue ex
        Log.warn(exception: ex) { "Failed to read #{compose_stack.config_files.first}" }
        ""
      end
    {% end %}
  end

  # True when compose action endpoints may touch docker: the compose
  # view enabled, and actions either explicitly enabled with
  # authentication or simulated on a demo build.
  private def self.compose_actions_allowed? : Bool
    Grafito.compose_enabled? && Grafito.actions_available?
  end

  # Whitelist for stack and service names coming from URLs: docker
  # compose names are alphanumeric with dashes, underscores and dots.
  private def self.valid_compose_name?(name : String?) : Bool
    return false unless name
    !name.empty? && !name.starts_with?('.') && name.matches?(/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/)
  end

  # The `docker compose -f <files>` prefix shared by every compose
  # command. Config files come from the `docker compose ls` snapshot,
  # never from user input.
  private def self.compose_command_prefix(compose_stack : ComposeStatus::Stack) : Array(String)
    ["docker", "compose"] + compose_stack.config_files.flat_map { |config_file| ["-f", config_file] }
  end
end
