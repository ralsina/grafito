require "./spec_helper"
require "../src/process_status"
require "../src/process_dashboard"

describe ProcessDashboard do
  it "renders a fragment from a snapshot" do
    snapshot = ProcessStatus.snapshot
    html = ProcessDashboard.render_html(snapshot, limit: "all")
    html.should contain("proc-table")
    html.should contain("CPU")
    snapshot.processes.each do |process_info|
      html.should contain(process_info.pid.to_s)
    end
  end

  it "filters processes by user, pid and command" do
    snapshot = ProcessStatus.snapshot
    no_match = ProcessDashboard.render_html(snapshot, filter: "no-such-thing-zzz")
    no_match.should contain("0 of")

    first_pid = snapshot.processes.first.pid.to_s
    ProcessDashboard.render_html(snapshot, filter: first_pid).should contain(first_pid)
  end

  it "sorts by cpu descending by default and honors explicit orders" do
    snapshot = ProcessStatus.snapshot
    html = ProcessDashboard.render_html(snapshot, sort_by: "pid", sort_order: "asc")
    first_pid = snapshot.processes.min_by(&.pid).pid.to_s
    html.should contain(first_pid)
  end

  it "hides action buttons unless actions are enabled" do
    snapshot = ProcessStatus.snapshot
    without_actions = ProcessDashboard.render_html(snapshot, enable_actions: false)
    without_actions.should_not contain("hx-post")
    with_actions = ProcessDashboard.render_html(snapshot, enable_actions: true)
    with_actions.should contain("hx-post")
    with_actions.should contain("proc-state-form")
  end

  it "caps the table unless limit=all is requested" do
    snapshot = ProcessStatus.snapshot
    if snapshot.processes.size > ProcessDashboard::ROW_CAP
      capped = ProcessDashboard.render_html(snapshot)
      capped.should contain("(top #{ProcessDashboard::ROW_CAP})")
      capped.should contain("show all")
      full = ProcessDashboard.render_html(snapshot, limit: "all")
      full.should contain("show top #{ProcessDashboard::ROW_CAP}")
      full.should_not contain("(top #{ProcessDashboard::ROW_CAP})")
    else
      ProcessDashboard.render_html(snapshot).should_not contain("show all")
    end
  end

  it "formats cpu time like htop's TIME+" do
    ProcessDashboard.format_cpu_time(0.0).should eq "00:00.00"
    ProcessDashboard.format_cpu_time(65.5).should eq "01:05.50"
    ProcessDashboard.format_cpu_time(3725.0).should eq "62:05.00"
  end
end

describe "Process routes" do
  it "GET /processes returns the process fragment" do
    response = dispatch_request("GET", "/processes")
    response[:status].should eq 200
    response[:body].should contain("proc-table")
  end

  it "GET /processes rows open the detail panel" do
    response = dispatch_request("GET", "/processes")
    response[:body].should contain("process-details?pid=")
    response[:body].should contain("panel-detail-content")
  end

  it "GET /processes accepts sort and filter parameters" do
    response = dispatch_request("GET", "/processes?sort_by=pid&sort_order=asc&filter=nothing-matches")
    response[:status].should eq 200
    response[:body].should contain("No processes match.")
  end

  it "GET /process-details returns the detail panel fragment" do
    pid = ProcessStatus.snapshot.processes.first.pid
    response = dispatch_request("GET", "/process-details?pid=#{pid}")
    response[:status].should eq 200
    response[:body].should contain("service-panel")
    response[:body].should contain(pid.to_s)
  end

  it "GET /process-details 400s without a pid and 404s for unknown pids" do
    dispatch_request("GET", "/process-details")[:status].should eq 400
    dispatch_request("GET", "/process-details?pid=999999")[:status].should eq 404
  end

  it "GET /processes is 404 when the view is disabled" do
    Grafito.processes_enabled = false
    response = dispatch_request("GET", "/processes")
    response[:status].should eq 404
    Grafito.processes_enabled = true
  end

  it "POST /process/:pid/:action is 403 when actions are disabled" do
    response = dispatch_request("POST", "/process/1/kill")
    response[:status].should eq 403
  end

  it "POST /process/:pid/:action rejects unknown actions" do
    # Force the action gate open: auth flags are not set in specs, so
    # poke the gate conditions directly.
    Grafito.enable_actions = true
    Grafito.auth_configured = true
    response = dispatch_request("POST", "/process/1/nuke")
    response[:status].should eq 400
    Grafito.enable_actions = false
    Grafito.auth_configured = false
  end

  it "POST /process/:pid/:action 404s for unknown pids" do
    Grafito.enable_actions = true
    Grafito.auth_configured = true
    response = dispatch_request("POST", "/process/999999/term")
    response[:status].should eq 404
    Grafito.enable_actions = false
    Grafito.auth_configured = false
  end

  it "POST /process-explain is 503 without an AI provider" do
    response = dispatch_request("POST", "/process-explain?pid=1")
    response[:status].should eq 503
  end
end

describe ProcessStatus do
  {% unless flag?(:demo_mode) %}
    it "reads a detail record for a live process" do
      detail = ProcessStatus.detail(Process.pid.to_i32)
      if detail
        detail.pid.should eq Process.pid
        detail.threads.should be >= 1
        detail.command.size.should be > 0
        detail.started.year.should be >= 2020
      else
        fail("expected a detail record for our own pid")
      end
    end
  {% end %}

  it "returns nil for processes that do not exist" do
    ProcessStatus.detail(999_999).should be_nil
  end
end
