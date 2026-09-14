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

require "./compose_status"
require "./compose_jobs"

module ComposeDashboard
  extend self

  Log = ::Log.for(self)

  # Renders the compose view fragment. `enable_actions` gates every
  # state-changing button, mirroring the dashboard's flag.
  def render_html(
    stacks : Array(ComposeStatus::Stack),
    enable_actions : Bool = false,
  ) : String
    HTML.build do
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
        stacks.each do |compose_stack|
          html stack_section(compose_stack, enable_actions)
        end
      end
    end
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

  # One stack: header with status and actions, optional job output
  # area, then the service table.
  private def stack_section(compose_stack : ComposeStatus::Stack, enable_actions : Bool) : String
    HTML.build do
      div(class: "compose-stack") do
        div(class: "compose-stack-header") do
          tag("h3") do
            text compose_stack.name
            html status_pill(compose_stack.status.empty? ? "unknown" : compose_stack.status)
          end
          div(class: "compose-stack-actions") do
            if enable_actions && compose_stack.actionable?
              html stack_action_button(compose_stack, "up", "play_arrow", "Start stack (up -d)")
              html stack_action_button(compose_stack, "stop", "stop", "Stop stack")
              html stack_action_button(compose_stack, "restart", "restart_alt", "Restart stack")
              html stack_action_button(compose_stack, "update", "update", "Pull images and up -d")
            end
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
              td(colspan: enable_actions ? "6" : "5", style: "text-align: center; padding: 1em;") do
                text "No containers found for this stack."
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
          text HTML.escape(compose_service.service)
        end
        td(title: compose_service.image) do
          text HTML.escape(compose_service.image)
        end
        td do
          text HTML.escape(compose_service.ports)
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
  def service_details_fragment(
    compose_service : ComposeStatus::Service,
    enable_actions : Bool = false,
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
            span { text compose_service.ports.empty? ? "—" : compose_service.ports }
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

        div(class: "service-panel-ai") do
          button(
            {
              "class":        "service-panel-explain",
              "title":        "Show the recent log tail for this service",
              "hx-get":       logs_url(compose_service.stack, compose_service.service),
              "hx-target":    "#compose-logs-content",
              "hx-swap":      "innerHTML",
              "hx-indicator": "#loading-spinner",
            }
          ) do
            span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
              text "article"
            end
            text " Service logs"
          end
          div(id: "compose-logs-content") { }
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
        text HTML.escape(value)
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
        text HTML.escape(value)
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
        text HTML.escape(value)
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
end
