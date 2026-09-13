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
