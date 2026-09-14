# # timeline.cr
#
# At work we use DataDog and I always liked how it showed a histogram of
# **when** all the events you are seeing happened. While not nearly as
# fancy (I am *not* a billion-dollar corporation) this is sort of the
# same thing. The buckets adapt to the time span of the entries (between
# 1 minute and 1 day) and empty buckets are filled with zeros, so the
# shape of the chart reflects the passage of time, not just the buckets
# that happen to have data.

require "time"
require "html"            # For HTML.escape
require "./journalctl"    # For Journalctl::LogEntry type
require "./metrics_store" # For the optional metrics overlay

module Timeline
  extend self

  # A bucket in the frequency timeline. `count` is the number of entries
  # in the bucket; `err`/`warn`/`info` are severity sub-counts used to
  # stack the bar segments (err: priority 0-3, warn: 4, info: 5-7).
  alias TimelinePoint = NamedTuple(start_time: Time, count: Int32, err: Int32, warn: Int32, info: Int32)

  # Candidate bucket widths, in seconds. The smallest interval that
  # yields at most MAX_BUCKETS buckets for the data's time span wins.
  BUCKET_INTERVALS = [60, 300, 600, 900, 1800, 3600, 7200, 14400, 43200, 86400]

  MAX_BUCKETS = 48

  # Generates a timeline of log entry frequencies, bucketed by an interval
  # adapted to the time span of the entries. The returned array always
  # covers the full span contiguously: buckets without entries are
  # included with a count of zero.
  def generate_frequency_timeline(
    logs : Array(Journalctl::LogEntry),
    location : Time::Location = Time::Location.local,
  ) : Array(TimelinePoint)
    return [] of TimelinePoint if logs.empty?

    # Work on the wall clock of the given location so bucket boundaries
    # line up with the timestamps shown in the table.
    oldest = logs.min_of(&.timestamp).in(location)
    newest = logs.max_of(&.timestamp).in(location)
    span = (newest - oldest).total_seconds

    interval = BUCKET_INTERVALS.find { |seconds| span / seconds < MAX_BUCKETS } || BUCKET_INTERVALS.last

    first_boundary = align_to_interval(oldest, interval)
    num_buckets = (((newest - first_boundary).total_seconds / interval) + 1).to_i

    buckets = Array.new(num_buckets) do |index|
      {start_time: first_boundary + (interval * index).seconds, count: 0, err: 0, warn: 0, info: 0}
    end

    logs.each do |entry|
      local_time = entry.timestamp.in(location)
      index = ((local_time - first_boundary).total_seconds / interval).to_i
      index = 0 if index < 0
      index = num_buckets - 1 if index >= num_buckets

      bucket = buckets[index]
      priority = entry.priority.to_i? || 6
      err = priority <= 3 ? 1 : 0
      warn = priority == 4 ? 1 : 0
      info = err + warn == 0 ? 1 : 0
      buckets[index] = {
        start_time: bucket[:start_time],
        count:      bucket[:count] + 1,
        err:        bucket[:err] + err,
        warn:       bucket[:warn] + warn,
        info:       bucket[:info] + info,
      }
    end

    buckets
  end

  # Floors a wall-clock time to the nearest interval boundary. All
  # BUCKET_INTERVALS are multiples of a minute, so minutes/hours/days
  # can be handled with simple truncation in local wall-clock time.
  private def align_to_interval(time : Time, interval : Int32) : Time
    if interval >= 86400
      days = interval // 86400
      day_start = time.at_beginning_of_day
      offset_days = ((time - day_start).total_days.to_i // days) * days
      day_start + offset_days.days
    elsif interval % 3600 == 0
      hours = interval // 3600
      hour_start = time.at_beginning_of_hour
      offset_hours = ((time - hour_start).total_hours.to_i // hours) * hours
      hour_start + offset_hours.hours
    else
      minutes = interval // 60
      minute_start = time.at_beginning_of_minute
      offset_min = ((time - minute_start).total_minutes.to_i // minutes) * minutes
      minute_start + offset_min.minutes
    end
  end

  # Formats a bucket start time for the axis labels: dates when the
  # buckets are a day wide, clock times otherwise.
  private def bucket_label(start_time : Time, interval : Int32) : String
    interval >= 86400 ? start_time.to_s("%m-%d") : start_time.to_s("%H:%M")
  end

  # Generates an SVG representation of a timeline: one stacked bar per
  # bucket (error/warn/info segments) plus time axis labels.
  #
  # Arguments:
  #
  # * timeline_data: An array of `TimelinePoint` data to plot.
  # * width: Total width of the SVG viewBox.
  # * height: Total height of the SVG viewBox.
  # * padding: Uniform padding around the chart area.
  # * bar_color: Fallback color for bars (bars are colored by severity
  #   classes via CSS; this is used only by the no-data variant).
  # * font_family: Font family for axis labels.
  # ameba:disable Metrics/CyclomaticComplexity
  def generate_svg_timeline(
    timeline_data : Array(TimelinePoint),
    width : Int32 = 800,
    height : Int32 = 100,
    padding : Int32 = 10,
    bar_color : String = "steelblue",
    font_family : String = "monospace",
    metrics : Array(Grafito::MetricsStore::MetricPoint) = [] of Grafito::MetricsStore::MetricPoint,
  ) : String
    svg = IO::Memory.new

    # Handle empty data case by returning a simple SVG
    if timeline_data.empty?
      svg << %(<svg width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" xmlns="http://www.w3.org/2000/svg">)
      svg << %(  <text x="#{width / 2}" y="#{height / 2}" class="no-data-text">No data available</text>)
      svg << %(</svg>)
      return svg.to_s
    end

    num_points = timeline_data.size
    chart_width = width - (2 * padding)
    # Vertical layout: labels at the top, bars below them
    label_y = 12.0
    chart_top = 20.0
    chart_bottom = height - padding
    chart_height = chart_bottom - chart_top

    # Determine max count for Y-axis scaling
    max_val = timeline_data.max_of(&.[:count])
    max_count = (max_val || 0).to_f
    max_count = 1.0 if max_count == 0.0

    # Infer the bucket interval from the first two buckets (falls back to
    # the full span when there is a single bucket).
    interval = if num_points > 1
                 (timeline_data[1][:start_time] - timeline_data[0][:start_time]).total_seconds
               else
                 3600
               end

    slot_width = chart_width.to_f / num_points
    actual_bar_width = (slot_width * 0.8).clamp(1.0, 60.0)
    bar_margin = (slot_width - actual_bar_width) / 2

    # Subtle system-metrics overlay (memory %, load) so the reader can
    # correlate system load with log activity. Drawn behind the bars;
    # points outside the bucket span are dropped.
    window_start = timeline_data[0][:start_time]
    window_end = timeline_data.last[:start_time] + interval.seconds
    window_span = [(window_end - window_start).total_seconds, 1.0].max
    in_window = metrics.select { |metric| metric.ts >= window_start && metric.ts <= window_end }
    max_load = in_window.empty? ? 0.0 : in_window.max_of(&.load1)
    metric_overlay = ""
    if !in_window.empty? && max_load > 0
      metric_x = ->(metric_ts : Time) {
        padding + ((metric_ts - window_start).total_seconds / window_span) * chart_width
      }
      mem_coords = in_window.map do |metric|
        y = chart_top + (1.0 - metric.mem_used_pct.clamp(0.0, 100.0) / 100.0) * chart_height
        "#{metric_x.call(metric.ts).round(2)},#{y.round(2)}"
      end
      load_coords = in_window.map do |metric|
        y = chart_bottom - (metric.load1 / max_load) * chart_height
        "#{metric_x.call(metric.ts).round(2)},#{y.clamp(chart_top, chart_bottom).round(2)}"
      end
      metric_overlay = String.build do |str|
        str << %(  <polyline class="tl-metric-line" stroke="var(--ok, #58a6ff)" points="#{mem_coords.join(" ")}" />)
        str << %(  <polyline class="tl-metric-line" stroke="var(--muted, #999)" stroke-dasharray="3 3" points="#{load_coords.join(" ")}" />)
      end
    end

    svg << %(<svg width="100%" height="#{height}" viewBox="0 0 #{width} #{height}" xmlns="http://www.w3.org/2000/svg" role="img" data-interval="#{interval.to_i}">)
    svg << %(  <style>)
    svg << %(    .tl-bar rect { fill: #{bar_color}; })
    svg << %(    .tl-label { fill: #999; font-family: #{font_family}; font-size: 12px; })
    svg << %(    .tl-metric-line { fill: none; stroke-width: 1.25; opacity: 0.55; })
    svg << %(  </style>)
    svg << metric_overlay

    timeline_data.each_with_index do |point, index|
      scale = chart_height / max_count
      err_h = (point[:err] * scale)
      warn_h = (point[:warn] * scale)
      info_h = (point[:info] * scale)

      bar_x = padding + index * slot_width + bar_margin
      info_y = chart_bottom - info_h
      warn_y = info_y - warn_h
      err_y = warn_y - err_h

      range_end = point[:start_time] + interval.seconds
      title = "#{point[:start_time].to_s("%H:%M")}–#{range_end.to_s("%H:%M")} · #{point[:count]} entries"
      details = [] of String
      details << "#{point[:err]} err" if point[:err] > 0
      details << "#{point[:warn]} warn" if point[:warn] > 0
      title += " (#{details.join(", ")})" unless details.empty?
      title = "#{point[:start_time].to_s("%Y-%m-%d ")}#{HTML.escape(title)}"

      svg << %(  <g class="tl-bar" data-start="#{point[:start_time].to_unix}">)
      unless info_h <= 0
        svg << %(    <rect x="#{bar_x.round(2)}" y="#{info_y.round(2)}" width="#{actual_bar_width.round(2)}" height="#{info_h.round(2)}" class="tl-info"><title>#{title}</title></rect>)
      end
      unless warn_h <= 0
        svg << %(    <rect x="#{bar_x.round(2)}" y="#{warn_y.round(2)}" width="#{actual_bar_width.round(2)}" height="#{warn_h.round(2)}" class="tl-warn"><title>#{title}</title></rect>)
      end
      unless err_h <= 0
        svg << %(    <rect x="#{bar_x.round(2)}" y="#{err_y.round(2)}" width="#{actual_bar_width.round(2)}" height="#{err_h.round(2)}" class="tl-err"><title>#{title}</title></rect>)
      end
      svg << %(  </g>)
    end

    # Time axis labels: first bucket, a few in between, and the last one.
    label_step = ((num_points - 1).to_f / 6).ceil.to_i
    label_step = 1 if label_step < 1
    interval_for_labels = if num_points > 1
                            (timeline_data[1][:start_time] - timeline_data[0][:start_time]).total_seconds.to_i
                          else
                            3600
                          end

    (0...num_points).step(label_step).each do |index|
      point = timeline_data[index]
      x = padding + index * slot_width
      svg << %(  <text x="#{x.round(2)}" y="#{label_y}" class="tl-label" text-anchor="start">#{bucket_label(point[:start_time], interval_for_labels)}</text>)
    end
    # Right-edge label for the end of the last bucket
    last_point = timeline_data.last
    last_end = last_point[:start_time] + interval_for_labels.seconds
    svg << %(  <text x="#{(width - padding).round(2)}" y="#{label_y}" class="tl-label" text-anchor="end">#{bucket_label(last_end, interval_for_labels)}</text>)
    if !in_window.empty? && max_load > 0
      legend_x = width / 2
      svg << %(  <text x="#{legend_x}" y="#{label_y}" class="tl-label" text-anchor="middle" opacity="0.8">— memory %   - - load (scaled)</text>)
    end

    svg << %(</svg>)
    svg.to_s
  end

  # Legend for the combined chart: severity bars plus the two metric
  # lines, colored exactly as they render in the SVG.
  def combined_legend : String
    HTML.build do
      div(class: "dashboard-legend") do
        span(class: "legend-item") do
          span(class: "legend-swatch", style: "background: var(--err)") { }
          text "errors"
        end
        span(class: "legend-item") do
          span(class: "legend-swatch", style: "background: var(--warn)") { }
          text "warnings"
        end
        span(class: "legend-item") do
          span(class: "legend-swatch", style: "background: var(--info)") { }
          text "info"
        end
        span(class: "legend-item") do
          span(class: "legend-line", style: "border-color: var(--info)") { }
          text "memory"
        end
        span(class: "legend-item") do
          span(class: "legend-line", style: "border-color: var(--err)") { }
          text "disk"
        end
      end
    end
  end

  # The combined dashboard chart: journal severity as stacked bars
  # (errors red, warnings amber, info blue — the same encoding as the
  # log view's timeline) with memory and disk usage as xy lines over
  # the same time span, so events and resource usage can be correlated
  # at a glance. Bars scale to their own maximum; both percentage
  # series share the full 0-100% scale.
  # Renders the combined chart: journal severity as stacked bars with
  # memory and disk usage lines over the same time span. Window is
  # derived from the union of both series, so either may be missing.
  def self.generate_combined_svg(
    points : Array(Grafito::MetricsStore::MetricPoint),
    buckets : Array(TimelinePoint),
  ) : String
    svg = IO::Memory.new
    width = 800.0
    height = 120.0
    # Derive the time window from the union of both series: buckets may
    # exist without metric samples and vice versa.
    markers = [] of Time
    unless points.empty?
      markers << points.first.ts
      markers << points.last.ts
    end
    unless buckets.empty?
      markers << buckets.first[:start_time]
      markers << buckets.last[:start_time]
    end
    return "" if markers.empty?
    oldest = markers.min
    newest = markers.max
    span_sec = [(newest - oldest).total_seconds, 1.0].max

    svg << %(<svg width="100%" height="#{height.to_i}" viewBox="0 0 #{width.to_i} #{height.to_i}" )
    svg << %(preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg" role="img" class="dashboard-history-svg" )
    svg << %(aria-label="Journal severity and memory, disk usage over the selected time window">)
    has_bars = buckets.any? { |bucket| (bucket[:err] + bucket[:warn] + bucket[:info]) > 0 }
    if has_bars
      svg << severity_bars(buckets, oldest, span_sec, width, height)
    end
    svg << %(  <polyline fill="none" stroke="var(--info, steelblue)" stroke-width="2" points="#{polyline_points(points, oldest, span_sec, width, height, &.mem_used_pct)}" />)
    svg << %(  <polyline fill="none" stroke="var(--err, darkorange)" stroke-width="2" stroke-dasharray="4 3" points="#{polyline_points(points, oldest, span_sec, width, height, &.disk_used_pct)}" />)
    svg << %(  <text x="8" y="#{(height - 8).to_i}" class="tl-label">#{oldest.to_s("%m-%d %H:%M")}</text>)
    svg << %(  <text x="#{(width - 8).to_i}" y="#{(height - 8).to_i}" text-anchor="end" class="tl-label">#{newest.to_s("%m-%d %H:%M")}</text>)
    svg << %(</svg>)
    svg.to_s
  end

  # Builds one stacked bar per severity bucket: info at the bottom,
  # warnings in the middle, errors on top — the same encoding as the
  # log view's timeline. Height scales so the busiest bucket reaches
  # the top of the chart; each bar carries a tooltip with its counts.
  private def self.severity_bars(
    buckets : Array(TimelinePoint),
    oldest : Time,
    span_sec : Float64,
    width : Float64,
    height : Float64,
  ) : String
    padding = 8.0
    usable = height - 2 * padding
    # Scale against a reference of at least 10 entries per bucket so a
    # sparse window doesn't render every bar at full height; busier
    # windows scale to their own maximum.
    reference = [buckets.max_of { |bucket| bucket[:err] + bucket[:warn] + bucket[:info] }.to_f, 10.0].max
    slot = (width - 2 * padding) / buckets.size
    bar_width = (slot * 0.7).round(2)
    bars = IO::Memory.new
    buckets.each do |bucket|
      total = bucket[:err] + bucket[:warn] + bucket[:info]
      next if total.zero?
      x = padding + ((bucket[:start_time] - oldest).total_seconds / span_sec) * (width - 2 * padding)
      total_h = (total.to_f / reference * usable).round(2)
      err_h = (bucket[:err].to_f / total * total_h).round(2)
      warn_h = (bucket[:warn].to_f / total * total_h).round(2)
      info_h = (total_h - err_h - warn_h).round(2)
      base = (height - padding).round(2)
      title = HTML.escape("#{bucket[:start_time].to_s("%H:%M")} · #{bucket[:err]} errors, #{bucket[:warn]} warnings, #{bucket[:info]} info")
      bars << %(  <g class="severity-bucket"><title>#{title}</title>)
      bars << %(    <rect x="#{x.round(2)}" y="#{(base - info_h).round(2)}" width="#{bar_width}" height="#{info_h}" fill="var(--info)" fill-opacity="0.85" stroke="none" />)
      bars << %(    <rect x="#{x.round(2)}" y="#{(base - info_h - warn_h).round(2)}" width="#{bar_width}" height="#{warn_h}" fill="var(--warn)" fill-opacity="0.9" stroke="none" />) if warn_h > 0
      bars << %(    <rect x="#{x.round(2)}" y="#{(base - info_h - warn_h - err_h).round(2)}" width="#{bar_width}" height="#{err_h}" fill="var(--err)" fill-opacity="1" stroke="none" />) if err_h > 0
      bars << %(  </g>)
    end
    bars.to_s
  end

  # Builds the x/y point list for one series: x spans the time range,
  # y is the percentage value mapped to the SVG height (inverted).
  private def polyline_points(
    points : Array(Grafito::MetricsStore::MetricPoint),
    oldest : Time,
    span_sec : Float64,
    width : Float64,
    height : Float64,
    &value : Grafito::MetricsStore::MetricPoint -> Float64
  ) : String
    padding = 8.0
    usable = height - 2 * padding
    points.map do |point|
      x = padding + ((point.ts - oldest).total_seconds / span_sec) * (width - 2 * padding)
      y = padding + (1.0 - value.call(point).clamp(0.0, 100.0) / 100.0) * usable
      "#{x.round(1)},#{y.round(1)}"
    end.join(" ")
  end
end
