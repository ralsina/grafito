require "./spec_helper"

describe "SystemStatus per-unit resource usage" do
  sample = <<-OUTPUT
    Id=nginx.service
    MemoryCurrent=456752128
    CPUUsageNSec=444135483000

    Id=systemd-journald.service
    MemoryCurrent=32243712
    CPUUsageNSec=98765432100

    Id=idle.service
    MemoryCurrent=[not set]
    CPUUsageNSec=[not set]
    OUTPUT

  it "parses systemctl show blocks by unit" do
    parsed = SystemStatus.parse_unit_show_output(sample)
    parsed.size.should eq(3)
    parsed["nginx.service"].cpu_ns.should eq(444135483000)
    parsed["nginx.service"].mem_bytes.should eq(456752128)
    parsed["systemd-journald.service"].cpu_ns.should eq(98765432100)
    parsed["idle.service"].cpu_ns.should be_nil
    parsed["idle.service"].mem_bytes.should be_nil
  end

  it "computes cpu pct from the ns delta" do
    # 10 s of CPU time over a 5 s window = 200% of one core.
    SystemStatus.unit_cpu_pct(10_000_000_000, 0, 5.0).should eq(200.0)
    # Counter went backwards (unit restarted): no reading.
    SystemStatus.unit_cpu_pct(5_000_000_000, 10_000_000_000, 5.0).should be_nil
    # No elapsed time: no reading.
    SystemStatus.unit_cpu_pct(5_000_000_000, 5_000_000_000, 0.0).should be_nil
  end

  it "renders the CPU and MEM columns when usage is provided" do
    units = [SystemStatus::UnitState.new(
      unit: "web.service", load_state: "loaded",
      active_state: "active", sub_state: "running", description: "web",
    )]
    snapshot = SystemStatus::Snapshot.new(
      timestamp: Time.local, load1: 1.0, mem_used_pct: 40.0,
      disk_used_pct: 50.0, uptime_sec: 86_400, units_total: 1,
      units_failed: 0, units: units,
    )
    usage = {
      "web.service" => SystemStatus::UnitResourceUsage.new(unit: "web.service", cpu_pct: 12.3, mem_mb: 1500.0),
    }
    html = Dashboard.render_html(snapshot, [] of Grafito::MetricsStore::MetricPoint, 0, unit_usage: usage)

    html.should contain("CPU")
    html.should contain("MEM")
    html.should contain("12.3%")
    html.should contain("1.5 GB")
  end
end
