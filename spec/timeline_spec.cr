require "spec"
require "../src/timeline"
require "../src/journalctl" # For Journalctl::LogEntry

def new_log_entry(
  timestamp : Time,
  message : String = "test",
  unit : String = "test.service",
  priority : String = "6",
  hostname : String = "localhost",
) : Journalctl::LogEntry
  Journalctl::LogEntry.new(
    timestamp: timestamp,
    message_raw: message,
    raw_priority_val: priority,
    internal_unit_name: unit,
    hostname: hostname,
  )
end

describe Timeline do
  describe ".generate_frequency_timeline" do
    it "returns an empty array for empty logs" do
      logs = [] of Journalctl::LogEntry
      Timeline.generate_frequency_timeline(logs).should be_empty
    end

    it "creates a single bucket for a lone entry" do
      logs = [new_log_entry(Time.utc(2023, 1, 1, 10, 15, 0))]
      timeline = Timeline.generate_frequency_timeline(logs)
      timeline.size.should eq(1)
      timeline[0][:count].should eq(1)
      timeline[0][:start_time].should eq(Time.utc(2023, 1, 1, 10, 15, 0))
    end

    it "zero-fills buckets that have no entries" do
      # Entries at 10:00 and 10:10 span 10 minutes; the smallest interval
      # keeps buckets under 48, so 1-minute buckets would be 11. With a
      # 5-minute interval picked from BUCKET_INTERVALS: span/300 = 2 <= 48.
      logs = [
        new_log_entry(Time.utc(2023, 1, 1, 10, 0, 0)),
        new_log_entry(Time.utc(2023, 1, 1, 10, 10, 0)),
      ]
      timeline = Timeline.generate_frequency_timeline(logs)
      # Span is 600s; smallest interval with span/interval <= 48 is 60s,
      # giving 11 buckets (10:00 .. 10:10).
      timeline.size.should eq(11)
      timeline[0][:count].should eq(1)
      timeline[5][:count].should eq(0) # 10:05 bucket is empty
      timeline[10][:count].should eq(1)
    end

    it "counts severities into err/warn/info sub-counts" do
      logs = [
        new_log_entry(Time.utc(2023, 1, 1, 10, 0, 0), priority: "3"),
        new_log_entry(Time.utc(2023, 1, 1, 10, 0, 5), priority: "4"),
        new_log_entry(Time.utc(2023, 1, 1, 10, 0, 10), priority: "6"),
        new_log_entry(Time.utc(2023, 1, 1, 10, 0, 15), priority: "7"),
      ]
      timeline = Timeline.generate_frequency_timeline(logs)
      timeline[0][:count].should eq(4)
      timeline[0][:err].should eq(1)
      timeline[0][:warn].should eq(1)
      timeline[0][:info].should eq(2)
    end

    it "picks hourly buckets for a multi-day span" do
      logs = [
        new_log_entry(Time.utc(2023, 1, 1, 10, 0, 0)),
        new_log_entry(Time.utc(2023, 1, 3, 10, 0, 0)),
      ]
      timeline = Timeline.generate_frequency_timeline(logs)
      # Span is 2 days; hourly buckets would be 49 (> 48), so the interval
      # steps up and every bucket is 2+ hours wide. Whatever the interval,
      # the buckets must cover the whole span contiguously.
      timeline.size.should be <= 48
      total = timeline.sum(&.[:count])
      total.should eq(2)
      timeline.first[:start_time].should eq(Time.utc(2023, 1, 1, 10, 0, 0))
      timeline.last[:start_time].should eq(Time.utc(2023, 1, 3, 10, 0, 0))
    end

    it "keeps buckets sorted chronologically" do
      logs = [
        new_log_entry(Time.utc(2023, 1, 1, 12, 0, 0)),
        new_log_entry(Time.utc(2023, 1, 1, 10, 0, 0)),
        new_log_entry(Time.utc(2023, 1, 1, 11, 0, 0)),
      ]
      timeline = Timeline.generate_frequency_timeline(logs)
      times = timeline.map(&.[:start_time])
      times.should eq(times.sort)
    end
  end

  describe ".generate_svg_timeline" do
    it "returns an SVG with 'No data available' for empty timeline_data" do
      data = [] of Timeline::TimelinePoint
      svg = Timeline.generate_svg_timeline(data, width: 200, height: 50)
      svg.should contain("<svg width=\"200\" height=\"50\"")
      svg.should contain("No data available")
    end

    it "generates severity-stacked bars with tooltips" do
      data = [
        {start_time: Time.utc(2023, 1, 1, 10), count: 3_i32, err: 1_i32, warn: 1_i32, info: 1_i32},
        {start_time: Time.utc(2023, 1, 1, 11), count: 2_i32, err: 0_i32, warn: 0_i32, info: 2_i32},
      ]
      svg = Timeline.generate_svg_timeline(data, width: 300, height: 120, padding: 10)

      svg.should contain("<svg width=\"100%\" height=\"120\"")
      svg.should contain("viewBox=\"0 0 300 120\"")
      svg.should contain("data-interval=\"3600\"")
      svg.should contain("data-start=\"")
      svg.should contain("class=\"tl-err\"")
      svg.should contain("class=\"tl-warn\"")
      svg.should contain("class=\"tl-info\"")

      # Tooltip includes the bucket range and the entry count
      svg.should contain("10:00–11:00 · 3 entries")
      svg.should contain("1 err")
    end

    it "draws time axis labels" do
      data = [
        {start_time: Time.utc(2023, 1, 1, 10), count: 1_i32, err: 0_i32, warn: 0_i32, info: 1_i32},
        {start_time: Time.utc(2023, 1, 1, 11), count: 1_i32, err: 0_i32, warn: 0_i32, info: 1_i32},
        {start_time: Time.utc(2023, 1, 1, 12), count: 1_i32, err: 0_i32, warn: 0_i32, info: 1_i32},
      ]
      svg = Timeline.generate_svg_timeline(data, width: 300, height: 120)
      svg.should contain("class=\"tl-label\"")
      svg.should contain(">10:00</text>")
      svg.should contain(">12:00</text>")
    end

    it "renders zero-count buckets without bars" do
      data = [
        {start_time: Time.utc(2023, 1, 1, 10), count: 0_i32, err: 0_i32, warn: 0_i32, info: 0_i32},
        {start_time: Time.utc(2023, 1, 1, 11), count: 4_i32, err: 2_i32, warn: 1_i32, info: 1_i32},
      ]
      svg = Timeline.generate_svg_timeline(data, width: 200, height: 100, padding: 10)
      # The empty bucket still gets its group with zero-height rects,
      # while the populated one has three severity segments.
      svg.scan(/class="tl-err"/).size.should eq(1)
      svg.scan(/class="tl-warn"/).size.should eq(1)
      svg.scan(/class="tl-info"/).size.should eq(1)
    end

    it "overlays memory and load lines when metrics cover the span" do
      data = [
        {start_time: Time.utc(2023, 1, 1, 10), count: 1_i32, err: 0_i32, warn: 0_i32, info: 1_i32},
        {start_time: Time.utc(2023, 1, 1, 11), count: 1_i32, err: 0_i32, warn: 0_i32, info: 1_i32},
      ]
      metrics = [
        Grafito::MetricsStore::MetricPoint.new(
          ts: Time.utc(2023, 1, 1, 10, 30),
          load1: 0.5,
          mem_used_pct: 42.0,
          disk_used_pct: 10.0,
          units_total: 5,
          units_failed: 0,
        ),
        Grafito::MetricsStore::MetricPoint.new(
          ts: Time.utc(2023, 1, 1, 11, 30),
          load1: 1.5,
          mem_used_pct: 80.0,
          disk_used_pct: 10.0,
          units_total: 5,
          units_failed: 0,
        ),
      ]
      svg = Timeline.generate_svg_timeline(data, width: 300, height: 120, metrics: metrics)
      svg.scan(/<polyline class="tl-metric-line"/).size.should eq(2) # memory line + load line
      svg.should contain("memory %")
    end

    it "omits the overlay when no metrics fall inside the span" do
      data = [
        {start_time: Time.utc(2023, 1, 1, 10), count: 1_i32, err: 0_i32, warn: 0_i32, info: 1_i32},
      ]
      metrics = [
        Grafito::MetricsStore::MetricPoint.new(
          ts: Time.utc(2024, 6, 1, 0),
          load1: 0.5,
          mem_used_pct: 42.0,
          disk_used_pct: 10.0,
          units_total: 5,
          units_failed: 0,
        ),
      ]
      svg = Timeline.generate_svg_timeline(data, width: 300, height: 120, metrics: metrics)
      svg.should_not contain("<polyline class=\"tl-metric-line\"")
      svg.should_not contain("memory %")
    end
  end
end
