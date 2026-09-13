require "./spec_helper"

# SystemStatus specs. In plain mode these run against the real system
# (like the journalctl specs), so they only assert basic invariants.
# With `-Dfake_journal` the fake snapshot is deterministic.
describe SystemStatus do
  it "returns a snapshot with sane values" do
    snapshot = SystemStatus.snapshot

    snapshot.load1.should be >= 0.0
    snapshot.uptime_sec.should be >= 0i64
    snapshot.mem_used_pct.should be >= 0.0
    snapshot.mem_used_pct.should be <= 100.0
    snapshot.disk_used_pct.should be >= 0.0
    snapshot.disk_used_pct.should be <= 100.0
    snapshot.units_total.should eq(snapshot.units.size)
    snapshot.units_failed.should eq(snapshot.units.count(&.failed?))
  end

  it "serializes a unit state to JSON" do
    unit = SystemStatus::UnitState.new(
      unit: "fake.service",
      load_state: "loaded",
      active_state: "failed",
      sub_state: "failed",
      description: "A broken unit",
    )
    unit.failed?.should be_true
    unit.running?.should be_false
    JSON.parse(unit.to_json)["active_state"].should eq("failed")
  end
end

describe Dashboard do
  it "formats uptimes" do
    Dashboard.format_uptime(30i64).should eq("0m")
    Dashboard.format_uptime(900i64).should eq("15m")
    Dashboard.format_uptime((2 * 3600 + 15 * 60).to_i64).should eq("2h 15m")
    Dashboard.format_uptime((3 * 86400 + 4 * 3600).to_i64).should eq("3d 4h")
  end

  it "builds a history SVG with one polyline per series" do
    points = [
      point_at(0, mem: 10.0, disk: 20.0),
      point_at(30, mem: 50.0, disk: 20.0),
      point_at(60, mem: 90.0, disk: 20.0),
    ]
    svg = Dashboard.generate_svg_history(points)
    svg.should contain("<svg")
    svg.should contain("polyline")
    svg.scan(/<polyline/).size.should eq(2)
  end

  it "renders the dashboard fragment with cards and services" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(snapshot, [] of Grafito::MetricsStore::MetricPoint, 3)
    html.should contain("Uptime")
    html.should contain("Services (#{snapshot.units_total})")
  end

  it "renders action buttons when actions are enabled" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(snapshot, [] of Grafito::MetricsStore::MetricPoint, 0, enable_actions: true)
    html.should contain("hx-post")
    html.should contain("hx-confirm")
  end

  it "renders clickable sort headers with a default ascending indicator" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(snapshot, [] of Grafito::MetricsStore::MetricPoint, 0)
    html.should contain("sortDashboard(&#39;unit&#39;)")
    html.should contain("sortDashboard(&#39;state&#39;)")
    html.should contain("sortDashboard(&#39;sub&#39;)")
    html.should contain("sortDashboard(&#39;description&#39;)")
    html.should contain("arrow_upward")
    html.should_not contain("arrow_downward")
    # The Unit column is the rightmost data column: its header comes last.
    description_index = html.index("Sort by description") || 0
    unit_index = html.index("Sort by unit") || html.size
    description_index.should be < unit_index
  end

  it "shows a descending indicator for the active sort column" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(
      snapshot,
      [] of Grafito::MetricsStore::MetricPoint,
      0,
      sort_by: "state",
      sort_order: "desc",
    )
    html.should contain("arrow_downward")
    html.should_not contain("arrow_upward")
  end

  it "sorts units by the requested column and direction" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(
      snapshot,
      [] of Grafito::MetricsStore::MetricPoint,
      0,
      sort_by: "unit",
      sort_order: "desc",
    )
    names = dashboard_unit_names(html)
    names.size.should be > 1
    lowered = names.map(&.downcase)
    descending = lowered.sort
    descending.reverse!
    lowered.should eq(descending)
  end

  it "sorts units by state when requested" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(
      snapshot,
      [] of Grafito::MetricsStore::MetricPoint,
      0,
      sort_by: "state",
      sort_order: "asc",
    )
    # The state column values appear in the tags inside each row; their
    # order in the fragment must be non-decreasing.
    states = html.scan(/<span class="tag[^"]*">([a-z]+)<\/span>/).map(&.[1])
    states.should eq(states.sort)
  end

  it "ignores unknown sort columns" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(
      snapshot,
      [] of Grafito::MetricsStore::MetricPoint,
      0,
      sort_by: "banana",
      sort_order: "sideways",
    )
    # Falls back to the default: unit, ascending.
    html.should contain("arrow_upward")
    html.should_not contain("arrow_downward")
    names = dashboard_unit_names(html)
    lowered = names.map(&.downcase)
    lowered.should eq(lowered.sort)
  end

  it "renders the time window select on the chart and a form wrapper" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(snapshot, [] of Grafito::MetricsStore::MetricPoint, 0)
    html.should contain("dashboard-window-select")
    html.should contain("dashboard-history")
    html.should contain("services-header")
    # The service filter input lives in the page topbar, not here; the
    # fragment form still wraps everything for self-contained requests.
    html.should contain("dashboard-form")
    html.should_not contain("dashboard-unit-filter")
    # Compact labels for the overlay selector; 6h is the default.
    html.should contain(">6h</option>")
    html.should contain(">15m</option>")
  end

  it "marks the selected time window and labels the errors card" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(
      snapshot,
      [] of Grafito::MetricsStore::MetricPoint,
      3,
      since_text: "-15m",
    )
    html.should contain("Errors (15m)")
    selected_options = html.scan(/<option[^>]*selected[^>]*>/).map(&.[0])
    selected_options.size.should eq(1)
    selected_options.first.should contain("-15m")
  end

  it "falls back to the default window for unknown since values" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(
      snapshot,
      [] of Grafito::MetricsStore::MetricPoint,
      3,
      since_text: "last week",
    )
    html.should contain("Errors (6h)")
    selected_options = html.scan(/<option[^>]*selected[^>]*>/).map(&.[0])
    selected_options.size.should eq(1)
    selected_options.first.should contain("-6h")
  end

  it "filters units by any displayed column" do
    # Name match.
    names = dashboard_unit_names(filter_spec_fragment("docker"))
    names.size.should be > 0
    names.each do |name|
      (name.downcase.includes?("docker")).should be_true
    end

    # Description match.
    by_description = dashboard_unit_names(filter_spec_fragment("secure shell"))
    by_description.should contain("sshd.service")

    # State match: "failed" returns exactly the failed unit.
    failed = dashboard_unit_names(filter_spec_fragment("failed"))
    failed.should eq(["fake-broken.service"])

    # Sub-state match: "running" returns every running unit.
    running = dashboard_unit_names(filter_spec_fragment("running"))
    running.sort.should eq(["docker.service", "nginx.service", "sshd.service"])
  end

  it "reports an empty result for a filter nothing matches" do
    html = filter_spec_fragment("grafito-no-such-unit-xyz")
    html.should contain("No units match the filter.")
  end
end

# A small deterministic snapshot for the filter specs, independent of
# the real system's unit list.
private def filter_spec_snapshot : SystemStatus::Snapshot
  units = [
    SystemStatus::UnitState.new("cron.service", "loaded", "active", "exited", "Regular background program processing"),
    SystemStatus::UnitState.new("docker.service", "loaded", "active", "running", "Docker Application Container Engine"),
    SystemStatus::UnitState.new("fake-broken.service", "loaded", "failed", "failed", "Fake failing service"),
    SystemStatus::UnitState.new("nginx.service", "loaded", "active", "running", "A high performance web server"),
    SystemStatus::UnitState.new("sshd.service", "loaded", "active", "running", "OpenBSD Secure Shell server"),
  ]
  SystemStatus::Snapshot.new(
    timestamp: Time.local,
    load1: 1.0,
    mem_used_pct: 50.0,
    disk_used_pct: 50.0,
    uptime_sec: 3600,
    units_total: units.size,
    units_failed: 1,
    units: units,
  )
end

# Renders the dashboard for the deterministic snapshot with a filter.
private def filter_spec_fragment(unit_filter : String) : String
  Dashboard.render_html(
    filter_spec_snapshot,
    [] of Grafito::MetricsStore::MetricPoint,
    0,
    unit_filter: unit_filter,
  )
end

# Extracts the unit names of the dashboard table rows, in row order.
# The rows are the only place that calls setUnitFilterAndTrigger().
private def dashboard_unit_names(html : String) : Array(String)
  html.scan(/setUnitFilterAndTrigger\(&quot;([^&]+)&quot;\)/).map(&.[1])
end

# Helper to build metric points relative to now.
private def point_at(seconds_ago : Int32, mem : Float64, disk : Float64) : Grafito::MetricsStore::MetricPoint
  Grafito::MetricsStore::MetricPoint.new(
    ts: Time.utc - seconds_ago.seconds,
    load1: 1.0,
    mem_used_pct: mem,
    disk_used_pct: disk,
    units_total: 5,
    units_failed: 0,
  )
end
