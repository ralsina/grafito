require "./spec_helper"

# SystemStatus specs. In plain mode these run against the real system
# (like the journalctl specs), so they only assert basic invariants.
# With `-Ddemo_mode` the fake snapshot is deterministic.
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

  it "returns status output for a unit, or nil without exploding" do
    output = SystemStatus.unit_status_output("sshd.service")
    if output
      output.should contain("sshd")
      output.should_not contain("\x1b") # no ANSI color codes
    else
      output.should be_nil
    end
  end

  it "parses /proc/net/dev rows, dropping loopback" do
    content = <<-TEXT
      Inter-|   Receive                                                |  Transmit
       face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
          lo: 1234567    9876    0    0    0     0          0         0  1234567    9876    0    0    0     0       0          0
        eth0: 51516553  418133    0    0    0     0          0         0 77118062  512104    0    0    0     0       0          0
         wg0: 4096      64    0    0    0     0          0         0     8192     128    0    0    0     0       0          0
      TEXT
    counters = SystemStatus.parse_net_dev(content)
    counters.size.should eq(2)
    counters["eth0"]?.should eq({rx: 51516553u64, tx: 77118062u64})
    counters["wg0"]?.should eq({rx: 4096u64, tx: 8192u64})
    counters["lo"]?.should be_nil
  end

  it "computes per-interface rates from consecutive readings" do
    current = {
      "eth0" => {rx: 115_000u64, tx: 21_000u64},
      "wg0"  => {rx: 5_000u64, tx: 5_000u64},
    }
    previous_rx = {"eth0" => 85_000u64, "wg0" => 5_000u64}
    previous_tx = {"eth0" => 20_000u64, "wg0" => 5_000u64}

    rates = SystemStatus.net_rates_from(current, previous_rx, previous_tx, 30.0)
    rates["eth0"].rx_bps.should eq(1000.0)
    rates["eth0"].tx_bps.should eq(1000.0 / 30.0)
    # wg0 moved zero bytes: omitted instead of stored as a zero rate.
    rates["wg0"]?.should be_nil
  end

  it "drops interfaces whose counters went backwards" do
    current = {"eth0" => {rx: 100u64, tx: 100u64}}
    rates = SystemStatus.net_rates_from(current, {"eth0" => 200u64}, {"eth0" => 200u64}, 30.0)
    rates.should be_empty
  end

  it "skips the rate hash entirely on the first reading" do
    current = {"eth0" => {rx: 100u64, tx: 100u64}}
    rates = SystemStatus.net_rates_from(current, {} of String => UInt64, {} of String => UInt64, 30.0)
    rates.should be_empty
  end
end

describe Dashboard do
  it "formats uptimes" do
    Dashboard.format_uptime(30i64).should eq("0m")
    Dashboard.format_uptime(900i64).should eq("15m")
    Dashboard.format_uptime((2 * 3600 + 15 * 60).to_i64).should eq("2h 15m")
    Dashboard.format_uptime((3 * 86400 + 4 * 3600).to_i64).should eq("3d 4h")
  end

  it "builds a combined chart with severity bars and metric lines" do
    points = [
      point_at(0, mem: 10.0, disk: 20.0),
      point_at(30, mem: 50.0, disk: 20.0),
      point_at(60, mem: 90.0, disk: 20.0),
    ]
    base = Time.utc - 60.seconds
    buckets = [
      {start_time: base, count: 0, err: 0, warn: 0, info: 0},
      {start_time: base + 30.seconds, count: 5, err: 2, warn: 1, info: 2},
      {start_time: base + 60.seconds, count: 1, err: 0, warn: 0, info: 1},
    ] of Timeline::TimelinePoint
    svg = Timeline.generate_combined_svg(points, buckets)
    svg.should contain("<svg")
    # Busy bucket: info + warn + err segments; quiet bucket: info only.
    svg.scan(/<rect/).size.should eq(4)
    svg.should contain("<polyline")
    # memory + swap + disk. Points without swap data (pre-swap history)
    # contribute an empty points list, which renders nothing.
    svg.scan(/<polyline/).size.should eq(3)
    svg.should contain("<title>")
    # All-zero buckets render no bars at all.
    zero_buckets = buckets.map { |bucket| {start_time: bucket[:start_time], count: 0, err: 0, warn: 0, info: 0} }
    svg_zero = Timeline.generate_combined_svg(points, zero_buckets)
    svg_zero.should_not contain("<rect")
  end

  it "provides a legend for the combined chart" do
    legend = Timeline.combined_legend
    legend.should contain("errors")
    legend.should contain("memory")
    legend.should contain("disk")
  end

  it "renders a network chart when history carries network samples" do
    points = [
      point_at(60, mem: 10.0, disk: 20.0, rx: 1000.0, tx: 100.0),
      point_at(30, mem: 50.0, disk: 20.0, rx: 2000.0, tx: 200.0),
      point_at(0, mem: 90.0, disk: 20.0, rx: 3000.0, tx: 300.0),
    ]
    svg = Timeline.generate_network_svg(points)
    svg.should contain("<svg")
    svg.scan(/<polyline/).size.should eq(2)
    # Auto-scaled: the scale label reflects the busiest sample (3300 * 1.1).
    svg.should contain("max 3.2 KiB/s")

    legend = Timeline.network_legend
    legend.should contain("rx")
    legend.should contain("tx")
  end

  it "renders no network chart when history predates network data" do
    points = [point_at(30, mem: 10.0, disk: 20.0), point_at(0, mem: 50.0, disk: 20.0)]
    Timeline.generate_network_svg(points).should be_empty
  end

  it "renders the dashboard fragment with cards and services" do
    snapshot = SystemStatus.snapshot
    html = Dashboard.render_html(snapshot, [] of Grafito::MetricsStore::MetricPoint, 3)
    html.should contain("Uptime")
    # The unit count is a card in the stats strip, not a heading.
    html.should contain(">Services</span>")
    html.should contain("<span class=\"stat-value\">#{snapshot.units_total}</span>")
  end

  it "renders swap and OOM cards, tolerant of swapless machines" do
    # A swapless snapshot renders an em-dash, not a fake 0%.
    snapshot = filter_spec_snapshot
    html = Dashboard.render_html(snapshot, [] of Grafito::MetricsStore::MetricPoint, 0, oom_kills: 3)
    html.should contain(">Swap</span>")
    html.should contain(">—</span>")
    html.should contain(">OOM (6h)</span>")
    html.should contain(">3</span>")

    swapped = SystemStatus::Snapshot.new(
      timestamp: snapshot.timestamp,
      load1: snapshot.load1,
      mem_used_pct: snapshot.mem_used_pct,
      disk_used_pct: snapshot.disk_used_pct,
      uptime_sec: snapshot.uptime_sec,
      units_total: snapshot.units_total,
      units_failed: snapshot.units_failed,
      units: snapshot.units,
      swap_used_pct: 95.0,
    )
    html = Dashboard.render_html(swapped, [] of Grafito::MetricsStore::MetricPoint, 0)
    html.should contain(">95.0%</span>")
    # Over the 90% default threshold the card carries the warning class.
    html.should contain("stat-value stat-error")
  end

  it "renders action buttons when actions are enabled" do
    snapshot = filter_spec_snapshot
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
    snapshot = filter_spec_snapshot
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
    snapshot = filter_spec_snapshot
    html = Dashboard.render_html(
      snapshot,
      [] of Grafito::MetricsStore::MetricPoint,
      0,
      sort_by: "state",
      sort_order: "asc",
    )
    # Only the State column pills, in row order, must be non-decreasing.
    states = html.scan(/<td class="dashboard-state-cell"><span class="tag[^"]*">([a-z]+)<\/span>/).map(&.[1])
    states.should eq(states.sort)
  end

  it "renders state and sub-state pills with state stripes" do
    snapshot = filter_spec_snapshot
    html = Dashboard.render_html(snapshot, [] of Grafito::MetricsStore::MetricPoint, 0)
    # Both State and Sub render as pills with semantic color classes...
    html.should contain("dashboard-state-cell")
    html.should contain("dashboard-sub-cell")
    html.should contain("tag-ok")
    # ...and each row carries its state class for the left stripe.
    html.should contain("du-state-active")
    html.should contain("du-state-failed")
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
    # The service filter input lives in the page topbar, not here; the
    # fragment form still wraps everything for self-contained requests.
    html.should contain("dashboard-form")
    html.should_not contain("dashboard-unit-filter")
    # Compact labels for the overlay selector; 6h is the default.
    html.should contain(">6h</option>")
    html.should contain(">15m</option>")
  end

  it "shows the network chart only when history carries network data" do
    snapshot = SystemStatus.snapshot
    with_net = [
      point_at(60, mem: 10.0, disk: 20.0, rx: 1000.0, tx: 100.0),
      point_at(0, mem: 50.0, disk: 20.0, rx: 1500.0, tx: 150.0),
    ]
    html = Dashboard.render_html(snapshot, with_net, 0)
    html.should contain("Network receive and transmit rates")
    html.scan(/dashboard-legend/).size.should eq(2)

    without_net = [point_at(60, mem: 10.0, disk: 20.0), point_at(0, mem: 50.0, disk: 20.0)]
    html = Dashboard.render_html(snapshot, without_net, 0)
    html.should_not contain("Network receive and transmit rates")
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

  {% if flag?(:demo_mode) %}
    it "shows contextual panel actions based on state and enablement" do
      snapshot = SystemStatus.snapshot
      broken = snapshot.units.find(&.unit.==("fake-broken.service"))
      running = snapshot.units.find(&.unit.==("docker.service"))
      if broken.nil? || running.nil?
        fail "fake units missing from the fake snapshot"
      end

      html = Dashboard.unit_details_fragment(
        broken,
        enable_actions: true,
        unit_flags: SystemStatus.unit_flags_map,
      )
      # A failed, disabled unit: start + restart (recovery) + enable.
      html.should contain("/start?from=panel")
      html.should contain("/restart?from=panel")
      html.should contain("/enable?from=panel")
      html.should_not contain("/stop?from=panel")
      html.should_not contain("/disable?from=panel")

      running_html = Dashboard.unit_details_fragment(
        running,
        enable_actions: true,
        unit_flags: SystemStatus.unit_flags_map,
      )
      # An active, enabled unit: stop/restart + disable, no start/enable.
      running_html.should contain("/stop?from=panel")
      running_html.should contain("/restart?from=panel")
      running_html.should contain("/disable?from=panel")
      running_html.should_not contain("/start?from=panel")
      running_html.should_not contain("/enable?from=panel")
    end

    it "omits panel actions when they are disabled" do
      snapshot = SystemStatus.snapshot
      broken = snapshot.units.find(&.unit.==("fake-broken.service"))
      if broken.nil?
        fail "fake-broken.service missing from the fake snapshot"
      end
      html = Dashboard.unit_details_fragment(broken, enable_actions: false)
      html.should_not contain("service-panel-actions")
    end

    it "shows contextual table actions per unit state and enablement" do
      snapshot = SystemStatus.snapshot
      html = Dashboard.render_html(
        snapshot,
        [] of Grafito::MetricsStore::MetricPoint,
        0,
        enable_actions: true,
        unit_flags: SystemStatus.unit_flags_map,
      )
      # A failed, disabled unit: start + enable, no stop.
      html.should contain("/unit/fake-broken.service/start")
      html.should contain("/unit/fake-broken.service/enable")
      html.should_not contain("/unit/fake-broken.service/stop")
      # An active, enabled unit: stop/restart + disable, no start.
      html.should contain("/unit/docker.service/stop")
      html.should contain("/unit/docker.service/restart")
      html.should contain("/unit/docker.service/disable")
      html.should_not contain("/unit/docker.service/start")
      # A static unit: no enablement buttons.
      html.should_not contain("/unit/cron.service/enable")
      html.should_not contain("/unit/cron.service/disable")
    end

    it "offers no actions for templates and masked units" do
      units = [
        SystemStatus::UnitState.new("some@.service", "loaded", "inactive", "dead", "A template unit"),
        SystemStatus::UnitState.new("masked.service", "loaded", "inactive", "dead", "A masked unit"),
      ]
      snapshot = SystemStatus::Snapshot.new(
        timestamp: Time.local,
        load1: 1.0,
        mem_used_pct: 50.0,
        disk_used_pct: 50.0,
        uptime_sec: 3600,
        units_total: units.size,
        units_failed: 0,
        units: units,
      )
      html = Dashboard.render_html(
        snapshot,
        [] of Grafito::MetricsStore::MetricPoint,
        0,
        enable_actions: true,
        unit_flags: {
          "masked.service" => SystemStatus::UnitFileFlags.new("masked", false),
        },
      )
      html.should contain(">some@.service</a>")
      html.should contain(">masked.service</a>")
      html.should_not contain("hx-post")
    end

    it "hides start and restart when systemd says CanStart=no" do
      units = [
        SystemStatus::UnitState.new("blocked.service", "loaded", "inactive", "dead", "Refuses manual start"),
      ]
      snapshot = SystemStatus::Snapshot.new(
        timestamp: Time.local,
        load1: 1.0,
        mem_used_pct: 50.0,
        disk_used_pct: 50.0,
        uptime_sec: 3600,
        units_total: units.size,
        units_failed: 0,
        units: units,
      )
      html = Dashboard.render_html(
        snapshot,
        [] of Grafito::MetricsStore::MetricPoint,
        0,
        enable_actions: true,
        unit_flags: {
          "blocked.service" => SystemStatus::UnitFileFlags.new("disabled", false),
        },
      )
      html.should contain(">blocked.service</a>")
      html.should_not contain("/blocked.service/start")
      html.should contain("/blocked.service/enable")
    end
  {% end %}
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

# Helper to build metric points relative to now. Optional network
# rates, so specs can exercise both pre-network and post-network
# history shapes.
private def point_at(seconds_ago : Int32, mem : Float64, disk : Float64, rx : Float64? = nil, tx : Float64? = nil) : Grafito::MetricsStore::MetricPoint
  Grafito::MetricsStore::MetricPoint.new(
    ts: Time.utc - seconds_ago.seconds,
    load1: 1.0,
    mem_used_pct: mem,
    disk_used_pct: disk,
    units_total: 5,
    units_failed: 0,
    net_rx_bps: rx,
    net_tx_bps: tx,
  )
end

{% if flag?(:demo_mode) %}
  it "generates clamped, varying fake metrics" do
    a = SystemStatus.fake_metrics_at(Time.utc)
    b = SystemStatus.fake_metrics_at(Time.utc + 7.minutes)
    a[:load1].should be >= 0.05
    a[:mem_used_pct].should be >= 5.0
    a[:mem_used_pct].should be <= 95.0
    a[:disk_used_pct].should be <= 100.0
    b[:mem_used_pct].should_not eq(a[:mem_used_pct])
  end
{% end %}
