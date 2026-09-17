require "./spec_helper"
require "file_utils"

# Each spec gets a fresh temp data dir, removed afterwards.
def with_store(&block : Grafito::MetricsStore -> Nil)
  data_dir = File.join(Dir.tempdir, "grafito-metrics-spec-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(data_dir)
  store = Grafito::MetricsStore.new(data_dir)
  begin
    block.call(store)
  ensure
    FileUtils.rm_rf(data_dir)
  end
end

def point_at(seconds_ago : Int32) : Grafito::MetricsStore::MetricPoint
  Grafito::MetricsStore::MetricPoint.new(
    ts: Time.utc - seconds_ago.seconds,
    load1: 1.5,
    mem_used_pct: 42.0,
    disk_used_pct: 55.0,
    units_total: 10,
    units_failed: 1,
  )
end

describe Grafito::MetricsStore do
  it "parses history lines written before the network field existed" do
    with_store do |store|
      # The exact 6-key line shape of the original format.
      legacy_line = {
        ts: Time.utc, load1: 0.4, mem_used_pct: 31.0,
        disk_used_pct: 48.0, units_total: 9, units_failed: 0,
      }.to_json
      path = File.join(store.data_dir, "metrics-#{Time.utc.to_s("%F")}.jsonl")
      File.write(path, legacy_line + "\n")

      reopened = Grafito::MetricsStore.new(store.data_dir)
      points = reopened.history(Time.utc - 1.minute)
      points.size.should eq(1)
      points.first.net_rx_bps.should be_nil
      points.first.net_tx_bps.should be_nil
      points.first.net.should be_nil
    end
  end

  it "roundtrips network data through the JSONL file" do
    with_store do |store|
      net = {
        "eth0" => SystemStatus::NetRate.new(rx_bps: 1200.5, tx_bps: 300.0),
        "wg0"  => SystemStatus::NetRate.new(rx_bps: 80.0, tx_bps: 90.0),
      }
      point = Grafito::MetricsStore::MetricPoint.new(
        ts: Time.utc - 30.seconds,
        load1: 1.5,
        mem_used_pct: 42.0,
        disk_used_pct: 55.0,
        units_total: 10,
        units_failed: 1,
        net_rx_bps: 1280.5,
        net_tx_bps: 390.0,
        net: net,
      )
      store.record(point)

      reopened = Grafito::MetricsStore.new(store.data_dir)
      loaded = reopened.history(Time.utc - 1.minute).first
      loaded.net_rx_bps.should eq(1280.5)
      loaded.net_tx_bps.should eq(390.0)
      loaded.net.should_not be_nil
      loaded.net.try(&.["eth0"].rx_bps).should eq(1200.5)
    end
  end

  it "sums per-interface rates into aggregate chart values" do
    net = {
      "eth0"  => SystemStatus::NetRate.new(rx_bps: 1000.0, tx_bps: 100.0),
      "wlan0" => SystemStatus::NetRate.new(rx_bps: 250.0, tx_bps: 25.0),
    }
    rx, tx = Grafito::MetricsStore.net_aggregates(net)
    rx.should eq(1250.0)
    tx.should eq(125.0)

    rx, tx = Grafito::MetricsStore.net_aggregates(nil)
    rx.should be_nil
    tx.should be_nil
  end

  it "records points and serves them from history" do
    with_store do |store|
      store.record(point_at(60))
      store.record(point_at(30))
      store.record(point_at(0))

      store.history(Time.utc - 2.minutes).size.should eq(3)
      store.history(Time.utc - 45.seconds).size.should eq(2)
      store.latest.try(&.mem_used_pct).should eq(42.0)
    end
  end

  it "persists points as daily JSONL files and reads them back" do
    with_store do |store|
      store.record(point_at(120))

      day_files = Dir.glob(File.join(store.data_dir, "metrics-*.jsonl"))
      day_files.size.should eq(1)
      File.basename(day_files.first).should match(/^metrics-\d{4}-\d{2}-\d{2}\.jsonl$/)

      # A second store instance (as after a restart) reads the same file.
      reopened = Grafito::MetricsStore.new(store.data_dir)
      reopened.history(Time.utc - 1.hour).size.should eq(1)
    end
  end

  it "skips malformed lines when reading history" do
    with_store do |store|
      store.record(point_at(60))
      path = Dir.glob(File.join(store.data_dir, "metrics-*.jsonl")).first
      File.open(path, "a", &.puts("{not json"))

      reopened = Grafito::MetricsStore.new(store.data_dir)
      reopened.history(Time.utc - 1.hour).size.should eq(1)
    end
  end

  it "prunes files older than the retention window" do
    with_store do |store|
      store.record(point_at(0))
      old_name = "metrics-#{(Time.utc - 30.days).to_s("%F")}.jsonl"
      File.write(File.join(store.data_dir, old_name), "{\"ts\":\"2020-01-01T00:00:00Z\"}\n")

      store.prune(7)

      File.exists?(File.join(store.data_dir, old_name)).should be_false
      Dir.glob(File.join(store.data_dir, "metrics-*.jsonl")).size.should eq(1)
    end
  end

  it "keeps files inside the retention window" do
    with_store do |store|
      recent_name = "metrics-#{(Time.utc - 2.days).to_s("%F")}.jsonl"
      File.write(File.join(store.data_dir, recent_name), "{}\n")

      store.prune(7)

      File.exists?(File.join(store.data_dir, recent_name)).should be_true
    end
  end

  it "falls back to a local dir when the requested dir is unusable" do
    blocked = File.join(Dir.tempdir, "grafito-blocked-#{Random::Secure.hex(4)}")
    File.write(blocked, "a file, not a directory")

    resolved = Grafito::MetricsStore.resolve_data_dir(File.join(blocked, "sub"))
    resolved.should_not eq(File.join(blocked, "sub"))
    Dir.exists?(resolved).should be_true
  ensure
    FileUtils.rm_rf(blocked) if blocked
    # The fallback lives under Dir.current; clean it up after asserting.
    FileUtils.rm_rf(File.join(Dir.current, "grafito-data"))
  end
end

{% if flag?(:demo_mode) %}
  it "pre-seeds a day of plausible fake history for the demo" do
    data_dir = File.join(Dir.tempdir, "grafito-seed-spec-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(data_dir)
    store = Grafito::MetricsStore.new(data_dir)
    Grafito::MetricsStore.seed_fake_history(store, 24.hours, 5.minutes)

    points = store.history(Time.utc - 25.hours)
    points.size.should eq(289) # 24h at 5-minute steps, inclusive

    # Values follow the fake wave: clamped, and not a dead-flat line.
    points.each do |point|
      point.mem_used_pct.should be >= 5.0
      point.mem_used_pct.should be <= 95.0
      point.load1.should be >= 0.05
    end
    unique_mem = points.map(&.mem_used_pct).uniq
    unique_mem.size.should be > 10
  ensure
    FileUtils.rm_rf(data_dir) if data_dir
  end

  it "does not re-seed when history already exists" do
    data_dir = File.join(Dir.tempdir, "grafito-seed-spec-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(data_dir)
    store = Grafito::MetricsStore.new(data_dir)
    Grafito::MetricsStore.seed_fake_history(store, 24.hours, 5.minutes)
    count_after_first = store.history(Time.utc - 25.hours).size

    Grafito::MetricsStore.seed_fake_history(store, 24.hours, 5.minutes)
    store.history(Time.utc - 25.hours).size.should eq(count_after_first)
  ensure
    FileUtils.rm_rf(data_dir) if data_dir
  end
{% end %}
