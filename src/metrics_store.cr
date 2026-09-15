# # Metrics store
#
# The dashboard shows history, and journald only has *log* history, so
# Grafito gathers its own: a background fiber takes a
# [SystemStatus](system_status.cr.html) snapshot every few seconds and
# appends it to a small JSONL file, one per day.
#
# The format is deliberately boring: one JSON object per line, one file
# per UTC day (`metrics-YYYY-MM-DD.jsonl`). It is trivially inspectable
# with standard tools, needs no database dependency, and a full week of
# 30-second samples is a few megabytes. Old files are pruned at startup
# according to the retention setting.

require "json"
require "log"
require "mutex"
require "time"

require "./system_status"

module Grafito
  # Stores metric points in memory (for quick "current" access) and in
  # daily JSONL files (for history). All public methods are safe to call
  # from both the sampler fiber and HTTP request fibers.
  class MetricsStore
    Log = ::Log.for(self)

    # One sampled point in time. Kept as a small flat record so it maps
    # 1:1 to a JSONL line.
    record MetricPoint,
      ts : Time,
      load1 : Float64,
      mem_used_pct : Float64,
      disk_used_pct : Float64,
      units_total : Int32,
      units_failed : Int32 do
      include JSON::Serializable
    end

    # In-memory cap: 24h of samples at a 30s interval.
    MAX_RECENT = 2880

    getter data_dir : String

    @mutex = Mutex.new
    @recent = Array(MetricPoint).new
    @write_failure_logged = false

    def initialize(@data_dir : String)
      Dir.mkdir_p(@data_dir) unless Dir.exists?(@data_dir)
    end

    # Converts a system snapshot into the flat point we persist.
    def self.point_from_snapshot(snapshot : SystemStatus::Snapshot) : MetricPoint
      MetricPoint.new(
        ts: snapshot.timestamp,
        load1: snapshot.load1,
        mem_used_pct: snapshot.mem_used_pct,
        disk_used_pct: snapshot.disk_used_pct,
        units_total: snapshot.units_total,
        units_failed: snapshot.units_failed,
      )
    end

    # Records a point: appended to the in-memory tail and to the current
    # day's file. File write failures are logged once (the store keeps
    # working from memory).
    def record(point : MetricPoint) : Nil
      @mutex.synchronize do
        @recent << point
        @recent.shift if @recent.size > MAX_RECENT
      end
      append_to_file(point)
    end

    # Returns the points recorded since the given time, newest last.
    # Day files are the source of truth; the in-memory tail is the
    # fallback for when file writes fail.
    def history(since : Time) : Array(MetricPoint)
      points = history_from_files(since)
      return points unless points.empty?
      history_from_memory(since)
    end

    # The most recent point, or nil when nothing has been sampled yet.
    def latest : MetricPoint?
      @mutex.synchronize { @recent.last? }
    end

    # Deletes day files older than the retention window. Called at
    # startup; also handy to call manually from specs.
    def prune(retention_days : Int32) : Nil
      cutoff_date = (Time.utc - retention_days.days).date
      Dir.glob(File.join(@data_dir, "metrics-*.jsonl")).each do |path|
        if file_date = date_from_filename(path)
          File.delete(path) if file_date < cutoff_date
        end
      end
    rescue ex
      Log.warn(exception: ex) { "Failed to prune metrics files in #{@data_dir}" }
    end

    # Starts the background sampler fiber: snapshots the system every
    # `interval_sec` seconds, records the point, and invokes the
    # optional callback (used for Gotify alert rules).
    def self.start(
      data_dir : String,
      interval_sec : Int32,
      retention_days : Int32,
      &on_sample : SystemStatus::Snapshot -> Nil
    ) : MetricsStore
      store = new(data_dir)
      store.prune(retention_days)
      {% if flag?(:demo_mode) %}
        # Demo builds pre-seed a day of plausible history so the chart
        # is full from the first page load instead of growing a stub.
        seed_fake_history(store, 24.hours, 5.minutes)
      {% end %}
      spawn(name: "metrics-sampler(#{interval_sec}s)") do
        loop do
          begin
            snapshot = SystemStatus.snapshot
            store.record(point_from_snapshot(snapshot))
            on_sample.try(&.call(snapshot))
          rescue ex
            Log.error(exception: ex) { "Metrics sampling iteration failed" }
          end
          sleep interval_sec.seconds
        end
      end
      store
    end

    # Demo only: fills the store with a `window`-long history of
    # plausible samples at `step` intervals, matching the live fake
    # snapshot's wave so there is no seam between seeded and live
    # points. No-op when history already exists.
    def self.seed_fake_history(store : MetricsStore, window : Time::Span, step : Time::Span) : Nil
      return unless store.history(Time.utc - window).empty?

      now = Time.utc
      steps = (window.total_seconds / step.total_seconds).to_i
      steps.downto(0) do |back|
        ts = now - (back * step.total_seconds).seconds
        metrics = SystemStatus.fake_metrics_at(ts)
        store.record(MetricPoint.new(
          ts: ts,
          load1: metrics[:load1],
          mem_used_pct: metrics[:mem_used_pct],
          disk_used_pct: metrics[:disk_used_pct],
          units_total: 5,
          units_failed: 1,
        ))
      end
    end

    # Ensures the requested data directory is usable, falling back to a
    # local directory when it cannot be created or written (e.g. the
    # packaged DynamicUser service has no home and /var/lib/grafito may
    # not be writable).
    def self.resolve_data_dir(requested : String) : String
      begin
        Dir.mkdir_p(requested) unless Dir.exists?(requested)
        probe = File.join(requested, ".grafito-write-test")
        File.write(probe, "ok")
        File.delete(probe)
        return requested
      rescue ex
        Log.warn(exception: ex) { "Data dir '#{requested}' is not writable, falling back to ./grafito-data" }
      end

      fallback = File.join(Dir.current, "grafito-data")
      begin
        Dir.mkdir_p(fallback) unless Dir.exists?(fallback)
      rescue ex
        Log.error(exception: ex) { "Fallback data dir '#{fallback}' is also unusable; metrics history will not persist" }
      end
      fallback
    end

    # Parses the UTC date out of a metrics file name, if well-formed.
    # `Time#date` returns a (year, month, day) tuple in current Crystal,
    # which compares correctly as a date.
    private def date_from_filename(path : String) : Tuple(Int32, Int32, Int32)?
      filename = File.basename(path)
      match = filename.match(/^metrics-(\d{4})-(\d{2})-(\d{2})\.jsonl$/)
      return unless match

      {match[1].to_i, match[2].to_i, match[3].to_i}
    end

    private def append_to_file(point : MetricPoint) : Nil
      path = File.join(@data_dir, "metrics-#{point.ts.to_utc.to_s("%F")}.jsonl")
      File.open(path, "a", &.puts(point.to_json))
      @write_failure_logged = false
    rescue ex
      unless @write_failure_logged
        Log.warn(exception: ex) { "Failed to write metrics to #{@data_dir}; will keep sampling in memory" }
        @write_failure_logged = true
      end
    end

    private def history_from_memory(since : Time) : Array(MetricPoint)
      @mutex.synchronize do
        @recent.select { |point| point.ts >= since }
      end
    end

    private def history_from_files(since : Time) : Array(MetricPoint)
      points = Array(MetricPoint).new

      day = since.to_utc.at_beginning_of_day
      now = Time.utc
      while day <= now
        path = File.join(@data_dir, "metrics-#{day.to_s("%F")}.jsonl")
        if File.exists?(path)
          File.each_line(path) do |line|
            next if line.strip.empty?
            point = MetricPoint.from_json(line)
            points << point if point.ts >= since
          rescue ex
            Log.debug(exception: ex) { "Skipping malformed metrics line" }
          end
        end
        day = day + 1.days
      end
      points.sort_by!(&.ts)
      points
    rescue ex
      Log.warn(exception: ex) { "Failed to read metrics history from #{@data_dir}" }
      [] of MetricPoint
    end
  end
end
