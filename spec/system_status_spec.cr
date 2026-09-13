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
