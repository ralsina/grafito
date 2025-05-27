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

    timeline = counts.map { |start_time, count| {start_time: start_time, count: count} }
    timeline.sort_by!(&.[:start_time])
  end

  # Generates an SVG representation of a timeline.
  #
  # Arguments:
  #   timeline_data: An array of `TimelinePoint` data to plot.
  #   width: Total width of the SVG.
  #   height: Total height of the SVG.
  #   padding: Uniform padding around the chart area.
  #   bar_color: Color of the bars.
  #   font_family: Font family for text elements in the SVG. (No longer used as text elements are removed)
  #
  # Returns:
  #   A string containing the SVG markup.
  def generate_svg_timeline(
    timeline_data : Array(TimelinePoint),
    width : Int32 = 800,
    height : Int32 = 100,
    padding : Int32 = 10,
    bar_color : String = "steelblue",
    font_family : String = "Arial, sans-serif", # Parameter kept for potential future use, but not currently applied
  ) : String
    svg = IO::Memory.new

    # Handle empty data case
    if timeline_data.empty?
      svg << %(<svg width="#{width}" height="#{height}" xmlns="http://www.w3.org/2000/svg">)
      svg << %(  <text x="#{width / 2}" y="#{height / 2}" class="no-data-text">No data available</text>)
      svg << %(</svg>)
      return svg.to_s
    end

    # Calculate actual chart dimensions
    chart_width = width - (2 * padding)
    chart_height = height - (2 * padding)

    # Determine max count for Y-axis scaling
    max_val = timeline_data.max_of(&.[:count])
    max_count = (max_val || 0).to_f
    max_count = 1.0 if max_count == 0.0 # Avoid division by zero if all counts are 0

    num_points = timeline_data.size
    slot_width = chart_width.to_f / num_points       # Width for each bar + its spacing
    actual_bar_width = slot_width * 0.8              # Bar takes 80% of the slot
    bar_margin = (slot_width - actual_bar_width) / 2 # Margin on each side of the bar within its slot

    # SVG header and styles
    svg << %(<svg width="100%" height="#{height}" viewBox="0 0 #{width} #{height}" xmlns="http://www.w3.org/2000/svg">)
    svg << %(  <style>)
    svg << %(    .bar { fill: #{bar_color}; }")
    svg << %(    .bar:hover { opacity: 0.8; }")
    # .text-label, .y-axis-label, .x-axis-label, .title-label classes and their font-family styles removed
    svg << %(  </style>)

    # Bars
    timeline_data.each_with_index do |point, index|
      bar_h = (point[:count].to_f / max_count) * chart_height
      bar_h = 0.0 if bar_h < 0 # Ensure non-negative height, though counts should be >= 0

      bar_x = padding + index * slot_width + bar_margin
      bar_y = height - padding - bar_h

      svg << %(  <rect x="#{bar_x.round(2)}" y="#{bar_y.round(2)}" width="#{actual_bar_width.round(2)}" height="#{bar_h.round(2)}" class="bar">)
      svg << %(    <title>#{HTML.escape(point[:start_time].to_s("%Y-%m-%d %H:%M") + ": " + point[:count].to_s)}</title>) # Tooltip
      svg << %(  </rect>)
    end

    svg << %(</svg>)
    svg.to_s
  end
end
