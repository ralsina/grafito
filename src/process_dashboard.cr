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
require "./ai/config"
require "./ai/request"
require "./journalctl"

module ProcessDashboard
  extend self

  Log = ::Log.for(self)

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

  # Rows shown by default. The full list is one POST away ("show all");
  # re-rendering hundreds of rows every few seconds costs CPU on both
  # ends for rows the user is not looking at.
  ROW_CAP = 100

  # Renders the process view fragment. `limit` is "all" (unpadded list)
  # or anything else (capped to ROW_CAP rows after sorting/filtering).
  # `history` and `severity_buckets` feed the same combo chart the log
  # stream and dashboard show; both default to empty (no chart).
  def render_html(
    snapshot : ProcessStatus::Snapshot,
    enable_actions : Bool = false,
    sort_by : String? = nil,
    sort_order : String? = nil,
    filter : String? = nil,
    limit : String? = nil,
    history : Array(Grafito::MetricsStore::MetricPoint) = [] of Grafito::MetricsStore::MetricPoint,
    severity_buckets : Array(Timeline::TimelinePoint) = [] of Timeline::TimelinePoint,
  ) : String
    sorted = sort_processes(snapshot.processes, sort_by, sort_order)
    needle = filter.to_s.strip.downcase
    matched = needle.empty? ? sorted : sorted.select do |process_info|
      process_info.user.downcase.includes?(needle) ||
        process_info.command.downcase.includes?(needle) ||
        process_info.pid.to_s.includes?(needle)
    end
    show_all = limit == "all"
    visible = show_all ? matched : matched.first(ROW_CAP)

    HTML.build do
      div(class: "dashboard-grid") do
        html card("CPU", "#{snapshot.core_pcts.sum.to_i}%", warn: snapshot.core_pcts.sum > snapshot.cpu_count * 90)
        html card("Tasks", "#{snapshot.tasks_total} (#{snapshot.tasks_running} R)")
        html card("Memory", memory_label(snapshot), warn: mem_used_pct(snapshot) > 90)
        html card("Load", format_load(snapshot.load1), warn: snapshot.load1 > snapshot.cpu_count)
        html meters_card(snapshot)
      end

      div(class: "dashboard-history proc-history") do
        if history.size >= 2
          html Timeline.combined_legend
          html Timeline.generate_combined_svg(history, severity_buckets)
        end
      end

      html proc_toolbar(snapshot, visible, matched, show_all, sort_by, sort_order, filter)

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
            tr do
              td(colspan: (SORT_COLUMNS.size + (enable_actions ? 1 : 0)).to_s, style: "text-align: center; padding: 1em;") do
                text "No processes match."
              end
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

  # The line above the table: how many rows are shown, the show
  # all/top-only toggle, and the hidden form carrying the current
  # sort/filter/limit so kill buttons (which post the refreshed
  # fragment) keep the table's state.
  private def proc_toolbar(
    snapshot : ProcessStatus::Snapshot,
    visible : Array(ProcessStatus::ProcessInfo),
    matched : Array(ProcessStatus::ProcessInfo),
    show_all : Bool,
    sort_by : String?,
    sort_order : String?,
    filter : String?,
  ) : String
    HTML.build do
      div(class: "proc-toolbar") do
        span(class: "proc-count") do
          text "#{visible.size} of #{snapshot.tasks_total} processes"
          if !show_all && matched.size > visible.size
            text " (top #{ROW_CAP})"
            a(href: "#", onclick: "return setProcessLimit(true);", title: "Show every matching process") do
              text " — show all"
            end
          elsif show_all && matched.size > ROW_CAP
            a(href: "#", onclick: "return setProcessLimit(false);", title: "Show only the top #{ROW_CAP} rows") do
              text " — show top #{ROW_CAP}"
            end
          end
        end
        form(id: "proc-state-form", class: "proc-state-form") do
          input(type: "hidden", name: "sort_by", value: sort_by.to_s)
          input(type: "hidden", name: "sort_order", value: sort_order.to_s)
          input(type: "hidden", name: "filter", value: filter.to_s)
          input(type: "hidden", name: "limit", value: show_all ? "all" : "")
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

  # The "Per core" summary card: one 2x2 total cell followed by the
  # per-core squares, or nothing at all before the first poll fills
  # the per-core readings.
  private def meters_card(snapshot : ProcessStatus::Snapshot) : String
    HTML.build do
      div(class: "stat proc-meters") do
        span(class: "stat-label") { text "Per core" }
        div(class: "proc-squares") do
          unless snapshot.core_pcts.empty?
            html total_square(snapshot.core_pcts.sum / snapshot.core_pcts.size)
          end
          snapshot.core_pcts.each_with_index do |pct, core_index|
            html core_meter(core_index, pct)
          end
        end
      end
    end
  end

  # The machine total as one 2x2 cell leading the grid: banded on the
  # percent of the whole machine (the average across cores), unlike the
  # per-core cells which band on percent of one core.
  private def total_square(avg_pct : Float64) : String
    fill_class = avg_pct >= 80 ? "proc-square-high" : (avg_pct >= 30 ? "proc-square-mid" : "proc-square-low")
    HTML.build do
      span(
        class: "proc-square proc-square-total #{fill_class}",
        title: "All cores: #{avg_pct.round(1)}%",
      ) { }
    end
  end

  # One CPU-meter cell: a solid colored square, no numbers. The color
  # banding (blue/amber/red) carries the coarse signal and the tooltip
  # the exact value; the cells form a 2-tall grid inside a summary
  # card, so a 16-core machine is 8 columns wide.
  private def core_meter(core_index : Int32, pct : Float64) : String
    fill_class = pct >= 80 ? "proc-square-high" : (pct >= 30 ? "proc-square-mid" : "proc-square-low")
    HTML.build do
      span(
        class: "proc-square #{fill_class}",
        title: "Core #{core_index}: #{pct.round(1)}%",
      ) { }
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

  # The journal query behind the severity chart is the expensive part
  # of the fragment, and the process view polls every few seconds: the
  # entries are cached briefly so polls stay cheap while the chart
  # still moves.
  CHART_ENTRY_TTL = 60.seconds

  private CHART_CACHE_LOCK = Mutex.new
  private CHART_CACHE      = {} of String => {entries: Array(Journalctl::LogEntry), at: Time}

  # Severity buckets over the dashboard's default window, matching the
  # combo chart in the log stream and the server dashboard.
  private def self.chart_data : Tuple(Array(Grafito::MetricsStore::MetricPoint), Array(Timeline::TimelinePoint))
    history = Grafito.metrics_store.try(&.history(Dashboard::DEFAULT_DASHBOARD_SINCE)) ||
              [] of Grafito::MetricsStore::MetricPoint
    buckets = Dashboard.severity_buckets(cached_journal_entries, history)
    {history, buckets}
  end

  private def self.cached_journal_entries : Array(Journalctl::LogEntry)
    key = "-6h"

    # Fast path: a fresh cache hit needs no I/O under the lock.
    CHART_CACHE_LOCK.synchronize do
      cached = CHART_CACHE[key]?
      if cached && (Time.local - cached[:at]) < CHART_ENTRY_TTL
        return cached[:entries]
      end
    end

    # Miss: run the journalctl subprocess WITHOUT holding the lock, so
    # concurrent requests are never blocked by this one's I/O. Two
    # simultaneous cold-cache requests may both query; that is harmless.
    entries = Dashboard.dashboard_journal_entries(key)

    CHART_CACHE_LOCK.synchronize do
      # Prefer a cache a concurrent refresher filled while we ran.
      cached = CHART_CACHE[key]?
      if cached && (Time.local - cached[:at]) < CHART_ENTRY_TTL
        return cached[:entries]
      end
      CHART_CACHE[key] = {entries: entries, at: Time.local}
      entries
    end
  end

  # Route helpers of the enclosing Grafito module, re-exposed here so
  # the route bodies below can use them verbatim.
  private def self.optional_query_param(env : HTTP::Server::Context, key : String) : String?
    Grafito.optional_query_param(env, key)
  end

  private def self.route_path(path : String) : String
    Grafito.route_path(path)
  end

  # Returns the process view fragment preserving the request's sort and
  # filter parameters, used by the kill endpoints so the table does not
  # jump back to the default ordering.
  private def self.render_process_fragment(env : HTTP::Server::Context) : String
    history, buckets = chart_data
    ProcessDashboard.render_html(
      ProcessStatus.snapshot,
      Grafito.enable_actions?,
      optional_query_param(env, "sort_by"),
      optional_query_param(env, "sort_order"),
      optional_query_param(env, "filter"),
      optional_query_param(env, "limit"),
      history,
      buckets,
    )
  end

  # ## Routes
  #
  # The process view owns its endpoints: the polled fragment, the
  # detail panel, the signal actions and the AI explanation.
  # ameba:disable Metrics/CyclomaticComplexity
  def self.register_routes
    # ## The `/processes` endpoint
    #
    # Returns the process view HTML fragment for HTMX: CPU meters,
    # summary cards and the process table. The frontend polls it every
    # 3 seconds. Parameters:
    # * `sort_by` (pid, user, state, cpu, mem, virt, res, time, cmd) and
    #   `sort_order` (asc/desc) control the table ordering.
    # * `filter` matches user, pid or command substring.
    get route_path("processes") do |env|
      unless Grafito.processes_enabled?
        env.response.status_code = 404
        next "Process view is disabled."
      end
      env.response.content_type = "text/html"
      history, buckets = chart_data
      ProcessDashboard.render_html(
        ProcessStatus.snapshot,
        Grafito.enable_actions?,
        optional_query_param(env, "sort_by"),
        optional_query_param(env, "sort_order"),
        optional_query_param(env, "filter"),
        optional_query_param(env, "limit"),
        history,
        buckets,
      )
    end

    # ## The `/process-details` endpoint
    #
    # Returns the process detail fragment for the right sidebar's Detail
    # tab: identity, resource usage, full command line, signal actions
    # (when enabled), an AI explanation button (when a provider is
    # configured) and a jump into the process's logs.
    #
    # Example usage:
    # ```text
    # GET /process-details?pid=1234
    # ```
    get route_path("process-details") do |env|
      unless Grafito.processes_enabled?
        env.response.status_code = 404
        next "Process view is disabled."
      end

      pid = optional_query_param(env, "pid").try(&.to_i32?)
      if pid.nil? || pid <= 0
        halt env, status_code: 400, response: "Missing or invalid pid."
      end

      detail = ProcessStatus.detail(pid)
      unless detail
        env.response.status_code = 404
        next "Process #{pid} not found (it may have exited)."
      end

      env.response.content_type = "text/html"
      ProcessDashboard.process_details_fragment(detail, Grafito.enable_actions?, !!Grafito.ai_provider)
    end

    # ## The process action endpoint
    #
    # `POST /process/<pid>/<term|kill|stop|cont>` sends a signal to the
    # named process. Gated exactly like the unit actions:
    # --enable-actions plus authentication, because killing processes is
    # the least read-only thing grafito can do. Requests with from=panel
    # (the sidebar buttons) get the refreshed detail fragment back, or
    # an error fragment on failure, so the panel always shows the
    # process's current state.
    post route_path("process/:pid/:action") do |env|
      unless Grafito.processes_enabled? && Grafito.enable_actions? && Grafito.auth_configured?
        env.response.status_code = 403
        next "Process actions are disabled. Start grafito with --enable-actions and authentication configured (GRAFITO_AUTH_USER/GRAFITO_AUTH_PASS) to allow them."
      end

      action = env.params.url["action"]
      signal = case action
               when "term" then Signal::TERM
               when "kill" then Signal::KILL
               when "stop" then Signal::STOP
               when "cont" then Signal::CONT
               else
                 env.response.status_code = 400
                 next "Invalid action '#{HTML.escape(action)}'."
               end

      pid = env.params.url["pid"].to_i32?
      if pid.nil? || pid <= 1 || !File.exists?("/proc/#{pid}")
        env.response.status_code = 404
        next "Process '#{HTML.escape(env.params.url["pid"])}' not found."
      end

      from_panel = optional_query_param(env, "from") == "panel"
      if ProcessStatus.signal(pid, signal)
        Log.info { "sent SIG#{action.upcase} to pid #{pid}" }
        env.response.content_type = "text/html"
        # Panel requests re-render the panel so it shows the state
        # after the signal (e.g. T after SIGSTOP); the table catches
        # up on its next 3s poll.
        if from_panel && (detail = ProcessStatus.detail(pid))
          next ProcessDashboard.process_details_fragment(detail, Grafito.enable_actions?, !!Grafito.ai_provider)
        end
        render_process_fragment(env)
      else
        message = "the kernel refused the signal (permissions, or the process just exited)"
        Log.error { "signal #{action} to pid #{pid} failed" }
        if from_panel
          env.response.status_code = 200
          env.response.content_type = "text/html"
          # htmx ignores error statuses, so a success status is needed
          # to show the failure inside the panel.
          next ProcessDashboard.process_action_error_fragment(action, pid, message)
        end
        env.response.status_code = 500
        "Failed to signal process #{pid}."
      end
    end

    # ## The `/process-explain` endpoint
    #
    # `POST /process-explain?pid=<pid>` asks the configured AI provider
    # to explain what a process is doing, using its /proc details and
    # recent journal lines mentioning it. Returns an HTML fragment for
    # the sidebar. 503 when no AI provider is configured, 404 for
    # unknown processes.
    post route_path("process-explain") do |env|
      unless Grafito.processes_enabled?
        env.response.status_code = 404
        next "Process view is disabled."
      end

      provider = Grafito.ai_provider
      unless provider
        env.response.content_type = "application/json"
        env.response.status_code = 503
        next {error: "AI features are disabled. Configure a provider key to enable explanations."}.to_json
      end

      pid = optional_query_param(env, "pid").try(&.to_i32?)
      if pid.nil? || pid <= 0
        env.response.content_type = "text/html"
        env.response.status_code = 400
        next "Missing or invalid pid."
      end

      detail = ProcessStatus.detail(pid)
      unless detail
        env.response.content_type = "text/html"
        env.response.status_code = 404
        next "Process #{pid} not found."
      end

      # Journal lines mentioning the process: its unit when it is
      # systemd-managed, otherwise a grep for its command name.
      recent = if detail.systemd_unit?
                 Journalctl.query(since: "-6h", unit: detail.unit, lines: 100) || [] of Journalctl::LogEntry
               else
                 Journalctl.query(since: "-6h", query: detail.comm, lines: 100) || [] of Journalctl::LogEntry
               end

      report = String.build do |str|
        str << "Process: #{detail.command} (pid #{detail.pid})\n"
        str << "User: #{detail.user} (uid #{detail.uid})\n"
        str << "State: #{detail.state}, threads: #{detail.threads}, parent pid: #{detail.ppid}\n"
        str << "Started: #{detail.started}\n"
        str << "CPU (lifetime average): #{detail.cpu_pct.round(1)}%, CPU time: #{detail.cpu_time_sec.round(1)}s\n"
        str << "Memory: #{detail.mem_pct.round(1)}% (#{detail.res_kb} KB resident, #{detail.virt_kb} KB virtual)\n"
        str << "Systemd unit: #{detail.systemd_unit? ? detail.unit : "none (not systemd-managed)"}\n"
        str << "\nRecent journal entries mentioning this process (last 6h, up to #{recent.size} lines):\n"
        recent.each do |entry|
          str << "[#{entry.formatted_timestamp_with_timezone}] [#{entry.formatted_priority}] #{entry.message}\n"
        end
      end

      begin
        request = Grafito::AI::Request.for_unit_diagnosis(report)
        response = provider.complete(request)
        Log.info { "AI process explanation generated for pid #{pid} (#{response.content.size} chars)" }
        env.response.content_type = "text/html"
        Dashboard.unit_ai_fragment(response.content)
      rescue ex : Exception
        Log.error(exception: ex) { "AI process explanation failed for pid #{pid}" }
        env.response.content_type = "text/html"
        # A 200 keeps htmx swapping so the user sees the failure inline.
        Dashboard.unit_ai_fragment("AI request failed: #{ex.message}")
      end
    end
  end
end
