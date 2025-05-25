require "time"
require "html"         # For HTML.escape
require "./journalctl" # For Journalctl::LogEntry type

module Timeline
  extend self # Allows calling methods like Timeline.generate_frequency_timeline

  # Alias for the data structure representing a point in the frequency timeline.
  alias TimelinePoint = NamedTuple(start_time: Time, count: Int32)

  # Generates a timeline of log entry frequencies.
  #
  # This function takes an array of log entries and groups them into time buckets
  # based on the specified interval, counting the number of entries in each bucket.
  #
  # Arguments:
  #   logs: An array of `Journalctl::LogEntry` objects. It's assumed that each
  #         entry has a `timestamp` attribute of type `Time`.
  #   Log entries will be bucketed by the hour.
  #
  # Returns:
  #   An array of `TimelinePoint` named tuples, sorted chronologically by `start_time`.
  #   Each `TimelinePoint` contains the `start_time` of the bucket and the `count`
  #   of log entries within that bucket.
  #   Returns an empty array if the input `logs` array is empty.
  def generate_frequency_timeline(
    logs : Array(Journalctl::LogEntry),
  ) : Array(TimelinePoint)
    return [] of TimelinePoint if logs.empty?

    counts = Hash(Time, Int32).new(0) # Initialize with default value 0 for counts
    logs.each do |entry|
      ts = entry.timestamp
      truncated_ts = ts.at_beginning_of_hour # Truncate to the hour
      counts[truncated_ts] += 1
    end

    timeline = counts.map { |start_time, count| {start_time: start_time, count: count}}
    timeline.sort_by!(&.[:start_time])
  end

  # Generates an SVG representation of a timeline.
  #
  # Arguments:
  #   timeline_data: An array of `TimelinePoint` data to plot.
  #   width: Total width of the SVG.
  #   height: Total height of the SVG.
  #   padding_*: Padding around the chart area for labels and title.
  #   bar_color: Color of the bars.
  #   axis_color: Color of the axis lines.
  #   label_color: Color of the text labels.
  #   grid_color: Color of the horizontal grid lines.
  #   time_label_format: Format string for time labels on the X-axis.
  #   title_text: Title of the chart.
  #   y_axis_ticks: Number of ticks/labels on the Y-axis.
  #
  # Returns:
  #   A string containing the SVG markup.
  def generate_svg_timeline(
    timeline_data : Array(TimelinePoint),
    width : Int32 = 800,
    height : Int32 = 300,
    padding_top : Int32 = 40,
    padding_right : Int32 = 30,
    padding_bottom : Int32 = 50,
    padding_left : Int32 = 50,
    bar_color : String = "steelblue",
    axis_color : String = "#555555",
    label_color : String = "#333333",
    grid_color : String = "#e0e0e0",
    time_label_format : String = "%H:%M",
    title_text : String = "Log Frequency Timeline",
    y_axis_ticks : Int32 = 5,
  ) : String
    svg = IO::Memory.new

    # Handle empty data case
    if timeline_data.empty?
      svg << %(<svg width="#{width}" height="#{height}" xmlns="http://www.w3.org/2000/svg">)
      svg << %(  <style>)
      svg << %(    .no-data-text { fill: #{label_color}; font-family: Arial, sans-serif; font-size: 16px; text-anchor: middle; dominant-baseline: middle; }")
      svg << %(  </style>)
      svg << %(  <text x="#{width / 2}" y="#{height / 2}" class="no-data-text">No data available</text>)
      svg << %(</svg>)
      return svg.to_s
    end

    # Calculate actual chart dimensions
    chart_width = width - padding_left - padding_right
    chart_height = height - padding_top - padding_bottom

    # Determine max count for Y-axis scaling
    max_val = timeline_data.map(&.[:count]).max
    max_count = (max_val || 0).to_f
    max_count = 1.0 if max_count == 0.0 # Avoid division by zero if all counts are 0

    num_points = timeline_data.size
    slot_width = chart_width.to_f / num_points       # Width for each bar + its spacing
    actual_bar_width = slot_width * 0.8              # Bar takes 80% of the slot
    bar_margin = (slot_width - actual_bar_width) / 2 # Margin on each side of the bar within its slot

    # SVG header and styles
    svg << %(<svg width="100%" height="#{height}" viewBox="0 0 #{width} #{height}" xmlns="http://www.w3.org/2000/svg">)
    svg << %(  <style>)
    svg << %(    .axis-line { stroke: #{axis_color}; stroke-width: 1; }")
    svg << %(    .grid-line { stroke: #{grid_color}; stroke-width: 0.5; }")
    svg << %(    .bar { fill: #{bar_color}; }")
    svg << %(    .bar:hover { opacity: 0.8; }") # Simple hover effect for bars
    svg << %(    .text-label { fill: #{label_color}; font-family: Arial, sans-serif; font-size: 10px; }")
    svg << %(    .y-axis-label { text-anchor: end; dominant-baseline: middle; }")
    svg << %(    .x-axis-label { text-anchor: middle; dominant-baseline: hanging; }")
    svg << %(    .title-label { fill: #{label_color}; font-family: Arial, sans-serif; font-size: 16px; text-anchor: middle; dominant-baseline: middle; }")
    svg << %(  </style>)

    # Chart Title
    # Title removed

    # Y-Axis (line, grid lines, and labels)
    svg << %(  <line x1="#{padding_left}" y1="#{padding_top}" x2="#{padding_left}" y2="#{height - padding_bottom}" class="axis-line" />)
    (0..y_axis_ticks).each do |i|
      tick_value = (max_count / y_axis_ticks) * i
      tick_y = height - padding_bottom - (tick_value / max_count) * chart_height
      if i > 0 && i < y_axis_ticks # Draw grid lines between main axes
        svg << %(  <line x1="#{padding_left + 1}" y1="#{tick_y.round(2)}" x2="#{width - padding_right}" y2="#{tick_y.round(2)}" class="grid-line" />)
      end
      # Y-axis labels removed
    end

    # X-Axis (line)
    svg << %(  <line x1="#{padding_left}" y1="#{height - padding_bottom}" x2="#{width - padding_right}" y2="#{height - padding_bottom}" class="axis-line" />)

    # Determine X-axis label interval to prevent overlap
    min_pixels_per_label = 40 # Approximate width for "HH:MM" + spacing
    label_interval = 1
    if num_points > 0 && chart_width > 0
      estimated_labels_can_fit = (chart_width / min_pixels_per_label).to_i.clamp(1, num_points)
      if num_points > estimated_labels_can_fit
        label_interval = (num_points.to_f / estimated_labels_can_fit).ceil.to_i
      end
    end

    # Bars and X-Axis Labels
    timeline_data.each_with_index do |point, index|
      bar_h = (point[:count].to_f / max_count) * chart_height
      bar_h = 0.0 if bar_h < 0 # Ensure non-negative height, though counts should be >= 0

      bar_x = padding_left + index * slot_width + bar_margin
      bar_y = height - padding_bottom - bar_h

      svg << %(  <rect x="#{bar_x.round(2)}" y="#{bar_y.round(2)}" width="#{actual_bar_width.round(2)}" height="#{bar_h.round(2)}" class="bar">)
      svg << %(    <title>#{HTML.escape(point[:start_time].to_s("%Y-%m-%d %H:%M") + ": " + point[:count].to_s)}</title>) # Tooltip
      svg << %(  </rect>)

      # X-axis labels removed
    end

    svg << %(</svg>)
    return svg.to_s
  end
end
