# # Process dashboard
#
# The process view is an HTMX fragment like the systemd dashboard: the
# frontend polls `GET /processes` every 3 seconds and swaps it into
# `#processes-view`. This module renders that fragment in htop's image:
# per-core CPU meters up top, summary cards, then the process table.
#
# Sorting and filtering happen server-side (the same pattern as the
# dashboard's unit table): clickable column headers and the topbar
# filter box trigger a fresh GET with `sort_by`, `sort_order` and
# `filter` parameters. Kill buttons are gated exactly like the unit
# actions (`--enable-actions` + authentication) and post to
# `/process/:pid/:action`, which responds with the refreshed fragment.

require "html_builder"

require "./process_status"

module ProcessDashboard
  extend self

  # Columns the table can be sorted by, with their labels. The keys are
  # whitelisted in the route; anything else falls back to CPU usage.
  SORT_COLUMNS = {
    "pid"   => "PID",
    "user"  => "User",
    "state" => "S",
    "cpu"   => "CPU%",
    "mem"   => "MEM%",
    "virt"  => "VIRT",
    "res"   => "RES",
    "time"  => "TIME+",
    "cmd"   => "Command",
  }

  # Renders the process view fragment.
  def render_html(
    snapshot : ProcessStatus::Snapshot,
    enable_actions : Bool = false,
    sort_by : String? = nil,
    sort_order : String? = nil,
    filter : String? = nil,
  ) : String
    sorted = sort_processes(snapshot.processes, sort_by, sort_order)
    needle = filter.to_s.strip.downcase
    visible = needle.empty? ? sorted : sorted.select do |process_info|
      process_info.user.downcase.includes?(needle) ||
        process_info.command.downcase.includes?(needle) ||
        process_info.pid.to_s.includes?(needle)
    end

    HTML.build do
      div(class: "dashboard-grid") do
        html card("CPU", "#{snapshot.core_pcts.sum.to_i}%", warn: snapshot.core_pcts.sum > snapshot.cpu_count * 90)
        html card("Tasks", "#{snapshot.tasks_total} (#{snapshot.tasks_running} R)")
        html card("Memory", memory_label(snapshot), warn: mem_used_pct(snapshot) > 90)
        html card("Load", format_load(snapshot.load1), warn: snapshot.load1 > snapshot.cpu_count)
      end

      div(class: "proc-meters") do
        if snapshot.core_pcts.empty?
          span(class: "proc-meters-hint") do
            text "CPU meters appear after the first refresh"
          end
        else
          snapshot.core_pcts.each_with_index do |pct, core_index|
            html core_meter(core_index, pct)
          end
        end
      end

      div(class: "proc-toolbar") do
        span(class: "proc-count") do
          text "#{visible.size} of #{snapshot.tasks_total} processes"
        end
        # Hidden form carrying the current sort/filter so kill buttons
        # (which post the refreshed fragment) keep the table's state.
        form(id: "proc-state-form", class: "proc-state-form") do
          input(type: "hidden", name: "sort_by", value: sort_by.to_s)
          input(type: "hidden", name: "sort_order", value: sort_order.to_s)
          input(type: "hidden", name: "filter", value: filter.to_s)
        end
      end

      table(class: "striped dashboard-units proc-table") do
        thead do
          tr do
            SORT_COLUMNS.each do |key, label|
              html sort_header(key, label, sort_by, sort_order)
            end
            if enable_actions
              th { text "Actions" }
            end
          end
        end
        tbody do
          if visible.empty?
            td(colspan: (SORT_COLUMNS.size + (enable_actions ? 1 : 0)).to_s, style: "text-align: center; padding: 1em;") do
              text "No processes match."
            end
          else
            visible.each do |process_info|
              html process_row(process_info, enable_actions)
            end
          end
        end
      end
    end
  end

  private def sort_processes(
    processes : Array(ProcessStatus::ProcessInfo),
    sort_by : String?,
    sort_order : String?,
  ) : Array(ProcessStatus::ProcessInfo)
    # Default view is CPU usage, biggest first, like htop. Otherwise the
    # requested order is honored literally: the column headers flip
    # between asc and desc on every click.
    descending = sort_by.nil? || sort_order != "asc"
    ordered = processes_sorted_by_column(processes, sort_by)
    descending ? ordered.reverse : ordered
  end

  private def processes_sorted_by_column(
    processes : Array(ProcessStatus::ProcessInfo),
    sort_by : String?,
  ) : Array(ProcessStatus::ProcessInfo)
    case sort_by
    when "pid"   then processes.sort_by(&.pid)
    when "user"  then processes.sort_by(&.user)
    when "state" then processes.sort_by(&.state)
    when "mem"   then processes.sort_by(&.mem_pct)
    when "virt"  then processes.sort_by(&.virt_kb)
    when "res"   then processes.sort_by(&.res_kb)
    when "time"  then processes.sort_by(&.cpu_time_sec)
    when "cmd"   then processes.sort_by(&.command.downcase)
    else              processes.sort_by(&.cpu_pct)
    end
  end

  private def sort_header(key : String, label : String, sort_by : String?, sort_order : String?) : String
    active = (sort_by || "cpu") == key
    next_order = if active
                   sort_order == "asc" ? "desc" : "asc"
                 else
                   # Numeric columns default to descending, text to asc.
                   {"pid", "user", "state", "cmd"}.includes?(key) ? "asc" : "desc"
                 end
    indicator = if active
                  arrow = next_order == "asc" ? "arrow_upward" : "arrow_downward"
                  %q(<span class="material-icons" aria-hidden="true" style="font-size: inherit; vertical-align: middle;">) + arrow + "</span>"
                else
                  ""
                end
    HTML.build do
      th({
        "style"   => "cursor: pointer; vertical-align: middle;" + (active ? " color: var(--txt);" : ""),
        "onclick" => "sortProcesses('#{key}')",
        "title"   => "Sort by #{label.downcase}",
      }) do
        text label
        html indicator
      end
    end
  end

  private def process_row(process_info : ProcessStatus::ProcessInfo, enable_actions : Bool) : String
    cpu_pct = process_info.cpu_pct
    cpu_class = cpu_pct >= 80 ? "proc-bar-high" : (cpu_pct >= 30 ? "proc-bar-mid" : "proc-bar-low")
    HTML.build do
      # Clicking anywhere on the row opens the process panel (the
      # sidebar's Detail tab), exactly like the dashboard's unit rows.
      tr(
        class: process_info.zombie? ? "proc-zombie" : "",
        title: "Show details for pid #{process_info.pid}",
        "hx-get": "process-details?pid=#{process_info.pid}",
        "hx-target": "#panel-detail-content",
        "hx-swap": "innerHTML",
        "hx-on:htmx:before-request": "panelSpinner('panel-detail-content')",
        "hx-on:htmx:after-request": "if(event.detail.successful){showLogPanel('detail')}else{panelError('panel-detail-content',event.detail.xhr.status);showLogPanel('detail')}",
      ) do
        td(class: "proc-pid") { text process_info.pid.to_s }
        td { text process_info.user }
        td do
          span(class: "proc-state proc-state-#{process_info.state}") { text process_info.state }
        end
        td(class: "proc-cpu") do
          div(class: "proc-bar") do
            div(class: "proc-bar-fill #{cpu_class}", style: "width: #{bar_width(cpu_pct)}%;") { }
            span(class: "proc-bar-text") { text "%.1f" % cpu_pct }
          end
        end
        td(class: "proc-mem") { text "%.1f" % process_info.mem_pct }
        td(class: "proc-num") { text human_size(process_info.virt_kb) }
        td(class: "proc-num") { text human_size(process_info.res_kb) }
        td(class: "proc-num") { text format_cpu_time(process_info.cpu_time_sec) }
        td(class: "proc-cmd", title: process_info.command) do
          text process_info.command
        end
        if enable_actions
          td(class: "proc-actions") do
            html kill_button(process_info.pid, "term", "skill", "Send SIGTERM to #{process_info.pid}")
            html kill_button(process_info.pid, "kill", "dangerous", "Send SIGKILL to #{process_info.pid}")
          end
        end
      end
    end
  end

  private def kill_button(pid : Int32, action : String, icon : String, title : String) : String
    HTML.build do
      button(
        class: "round-button",
        title: title,
        "hx-post": "process/#{pid}/#{action}",
        "hx-target": "#processes-view",
        "hx-swap": "innerHTML",
        "hx-confirm": "#{title}?",
        "hx-include": "#proc-state-form",
        "hx-indicator": "#loading-spinner",
        # The row itself opens the detail panel; a signal button must
        # not trigger it too.
        "onclick": "event.stopPropagation()",
      ) do
        span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
          text icon
        end
      end
    end
  end

  # One htop-style CPU meter: a vertical label and a bar. The exact
  # percentage lives in the tooltip; the color banding (blue/amber/red)
  # carries the coarse signal at a glance.
  private def core_meter(core_index : Int32, pct : Float64) : String
    fill_class = pct >= 80 ? "proc-bar-high" : (pct >= 30 ? "proc-bar-mid" : "proc-bar-low")
    HTML.build do
      div(class: "proc-meter", title: "Core #{core_index}: #{pct.round(1)}%") do
        span(class: "proc-meter-label") { text core_index.to_s }
        div(class: "proc-meter-track") do
          div(class: "proc-bar-fill #{fill_class}", style: "height: #{pct.round(1)}%;") { }
        end
      end
    end
  end

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

  private def bar_width(pct : Float64) : Float64
    # Percent of one core can exceed 100 for multithreaded processes;
    # cap the bar and let the number tell the truth.
    pct.clamp(0.0, 100.0)
  end

  private def memory_label(snapshot : ProcessStatus::Snapshot) : String
    if snapshot.mem_total_kb > 0
      "#{(snapshot.mem_used_kb / 1024).to_i}/" \
      "#{(snapshot.mem_total_kb / 1_048_576.0).round(1)}G"
    else
      "?"
    end
  end

  private def mem_used_pct(snapshot : ProcessStatus::Snapshot) : Float64
    return 0.0 if snapshot.mem_total_kb <= 0
    snapshot.mem_used_kb.to_f / snapshot.mem_total_kb * 100
  end

  private def format_load(load1 : Float64) : String
    "%.2f" % load1
  end

  # htop's TIME+ format: seconds as minutes:seconds.hundredths.
  def format_cpu_time(seconds : Float64) : String
    total = seconds.clamp(0.0, nil)
    minutes = (total / 60).to_i
    secs = total - minutes * 60
    "%02d:%05.2f" % {minutes, secs}
  end

  # ## The process detail panel
  #
  # Swapped into the sidebar's Detail tab when a table row is clicked,
  # using the same .service-panel markup the dashboard's unit panel
  # uses, so the panel's service-view mode (hiding the log-entry tabs)
  # works unchanged.

  def process_details_fragment(
    detail : ProcessStatus::ProcessDetail,
    enable_actions : Bool = false,
    ai_available : Bool = false,
  ) : String
    HTML.build do
      div(class: "service-panel") do
        tag("h4") do
          text "#{detail.command.size > 60 ? detail.command[0...57] + "..." : detail.command} (#{detail.pid})"
        end
        div(class: "service-panel-pills") do
          html state_pill(detail.state)
          if detail.systemd_unit?
            span(class: "state-pill") { text detail.unit }
          end
        end

        div(class: "service-panel-info proc-detail-info") do
          div do
            span(class: "stat-label") { text "User" }
            span { text "#{detail.user} (#{detail.uid})" }
          end
          div do
            span(class: "stat-label") { text "Parent" }
            span { text detail.ppid.to_s }
          end
          div do
            span(class: "stat-label") { text "Threads" }
            span { text detail.threads.to_s }
          end
          div do
            span(class: "stat-label") { text "Started" }
            span { text detail.started.to_s("%Y-%m-%d %H:%M:%S") }
          end
          div do
            span(class: "stat-label") { text "CPU (avg)" }
            span { text "%.1f%%" % detail.cpu_pct }
          end
          div do
            span(class: "stat-label") { text "CPU time" }
            span { text format_cpu_time(detail.cpu_time_sec) }
          end
          div do
            span(class: "stat-label") { text "Memory" }
            span { text "%.1f%% (%s of RAM)" % {detail.mem_pct, human_size(detail.res_kb)} }
          end
          div do
            span(class: "stat-label") { text "Virtual" }
            span { text human_size(detail.virt_kb) }
          end
        end

        tag("pre", class: "proc-detail-command") do
          text detail.command
        end

        if enable_actions
          div(class: "service-panel-actions") do
            html signal_button(detail, "term", "skill", "SIGTERM", "Ask #{detail.pid} to exit (SIGTERM)")
            if detail.stopped?
              html signal_button(detail, "cont", "play_arrow", "SIGCONT", "Resume #{detail.pid} (SIGCONT)")
            else
              html signal_button(detail, "stop", "pause", "SIGSTOP", "Pause #{detail.pid} (SIGSTOP)")
            end
            html signal_button(detail, "kill", "dangerous", "SIGKILL", "Force-kill #{detail.pid} (SIGKILL)")
            span(class: "service-panel-hint") { text "process signals" }
          end
        end

        if ai_available
          div(class: "service-panel-ai") do
            button(
              {
                "class"        => "service-panel-explain",
                "title"        => "Ask the AI to explain this process and its recent logs",
                "hx-post"      => "process-explain?pid=#{detail.pid}",
                "hx-target"    => "#service-ai-content",
                "hx-swap"      => "innerHTML",
                "hx-indicator" => "#loading-spinner",
              }
            ) do
              span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
                text "psychology"
              end
              text " Explain this process (AI)"
            end
            div(id: "service-ai-content") { }
          end
        end

        button(
          class: "service-panel-viewlogs",
          title: detail.systemd_unit? ? "Show the journal for #{detail.unit}" : "Search the journal for \"#{detail.comm}\"",
          onclick: "return setProcessLogsFilter(#{detail.unit.to_json}, #{detail.comm.to_json});",
        ) do
          span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
            text "article"
          end
          text detail.systemd_unit? ? " View logs for #{detail.unit}" : " Search logs for this process"
        end
      end
    end
  end

  # Error variant swapped into the panel when a signal from the panel
  # fails (process vanished, permission denied...), mirroring the
  # dashboard's action error fragment.
  def process_action_error_fragment(action : String, pid : Int32, message : String) : String
    HTML.build do
      div(class: "service-panel service-panel-error") do
        tag("h4") { text "PID #{pid}" }
        tag("p") do
          text "SIG#{action.upcase} failed: #{message}"
        end
      end
    end
  end

  # One signal button inside the panel. Panel actions refresh the panel
  # (from=panel) instead of the whole table.
  private def signal_button(detail : ProcessStatus::ProcessDetail, action : String, icon : String, label : String, title : String) : String
    HTML.build do
      button(
        class: "round-button",
        title: title,
        "hx-post": "process/#{detail.pid}/#{action}?from=panel",
        "hx-target": "#panel-detail-content",
        "hx-swap": "innerHTML",
        "hx-confirm": "#{title}?",
        "hx-indicator": "#loading-spinner",
      ) do
        span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
          text icon
        end
        text " #{label}"
      end
    end
  end

  private def state_pill(state : String) : String
    HTML.build do
      span(class: "state-pill proc-state-#{state}") { text state }
    end
  end

  private def human_size(kilobytes : Int64) : String
    return "0" if kilobytes <= 0
    if kilobytes >= 1_048_576
      "#{(kilobytes / 1_048_576.0).round(1)}G"
    elsif kilobytes >= 1024
      "#{(kilobytes / 1024.0).round(0).to_i}M"
    else
      kilobytes.to_s
    end
  end
end
