require "spec"
require "../src/timeline"
require "../src/journalctl" # For Journalctl::LogEntry

def new_log_entry(timestamp_str : String, message : String = "test", unit : String = "test.service", priority : String = "6")
  time = Time.parse_rfc3339(timestamp_str)
  Journalctl::LogEntry.new(
    timestamp: time,            # Pass the Time object to the 'timestamp' property
    message_raw: message,       # Pass the message string to the 'message_raw' property
    raw_priority_val: priority, # Pass the priority string to the 'raw_priority_val' property
    internal_unit_name: unit    # Pass the unit string to the 'internal_unit_name' property
  )
end

describe Timeline do
  # Unified helper to create LogEntry instances for tests
  # Accepts a timestamp string and optional message, unit, and priority.

  describe ".generate_frequency_timeline" do
    it "returns an empty array for empty logs" do
      logs = [] of Journalctl::LogEntry
      Timeline.generate_frequency_timeline(logs).should be_empty
    end

    it "groups logs by hour and counts them correctly" do
      logs = [
        new_log_entry("2023-01-01T10:15:00Z"),
        new_log_entry("2023-01-01T10:30:00Z"),
        new_log_entry("2023-01-01T11:05:00Z"),
        new_log_entry("2023-01-01T10:55:00Z"), # Another one in 10:00 hour
        new_log_entry("2023-01-01T12:00:00Z"),
      ]

      timeline = Timeline.generate_frequency_timeline(logs)

      timeline.size.should eq(3)

      # Check 10:00 hour
      point1 = timeline.find { |p| p[:start_time] == Time.utc(2023, 1, 1, 10, 0, 0) }
      point1.should_not be_nil
      point1.as(NamedTuple)[:count].should eq(3)

      # Check 11:00 hour
      point2 = timeline.find { |p| p[:start_time] == Time.utc(2023, 1, 1, 11, 0, 0) }
      point2.should_not be_nil
      point2.as(NamedTuple)[:count].should eq(1)

      # Check 12:00 hour
      point3 = timeline.find { |p| p[:start_time] == Time.utc(2023, 1, 1, 12, 0, 0) }
      point3.should_not be_nil
      point3.as(NamedTuple)[:count].should eq(1)

      # Check sorting
      timeline[0][:start_time].should eq(Time.utc(2023, 1, 1, 10, 0, 0))
      timeline[1][:start_time].should eq(Time.utc(2023, 1, 1, 11, 0, 0))
      timeline[2][:start_time].should eq(Time.utc(2023, 1, 1, 12, 0, 0))
    end

    it "handles logs with timestamps exactly on the hour" do
      logs = [
        new_log_entry("2023-01-01T10:00:00Z"),
        new_log_entry("2023-01-01T11:00:00Z"),
      ]
      timeline = Timeline.generate_frequency_timeline(logs)
      timeline.size.should eq(2)
      timeline[0][:start_time].should eq(Time.utc(2023, 1, 1, 10, 0, 0))
      timeline[0][:count].should eq(1)
      timeline[1][:start_time].should eq(Time.utc(2023, 1, 1, 11, 0, 0))
      timeline[1][:count].should eq(1)
    end
  end

  describe ".generate_svg_timeline" do
    it "returns an SVG with 'No data available' for empty timeline_data" do
      data = [] of Timeline::TimelinePoint
      svg = Timeline.generate_svg_timeline(data, width: 200, height: 50)
      svg.should contain("<svg width=\"200\" height=\"50\"")
      svg.should contain("No data available")
    end

    it "generates an SVG with correct structure for single data point" do
      data = [{start_time: Time.utc(2023, 1, 1, 10), count: 10_i32}]
      svg = Timeline.generate_svg_timeline(data, width: 200, height: 100, padding: 5, bar_color: "blue")

      svg.should contain("<svg width=\"100%\" height=\"100\"") # Check for responsive width
      svg.should contain("viewBox=\"0 0 200 100\"")
      svg.should contain(".bar { fill: blue; }")
      svg.should contain("<rect ") # Check for bar
      svg.should contain("<title>2023-01-01 10:00: 10</title>")

      # Chart height = 100 - (2*5) = 90. Bar height should be 90.
      svg.should contain("height=\"90.0\"")
    end

    it "generates an SVG with multiple bars scaled correctly" do
      data = [
        {start_time: Time.utc(2023, 1, 1, 10), count: 10_i32},
        {start_time: Time.utc(2023, 1, 1, 11), count: 20_i32}, # Max count
        {start_time: Time.utc(2023, 1, 1, 12), count: 5_i32},
      ]
      svg = Timeline.generate_svg_timeline(data, width: 300, height: 120, padding: 10, bar_color: "green")

      svg.should contain("<svg width=\"100%\" height=\"120\"")
      svg.should contain("viewBox=\"0 0 300 120\"")
      svg.should contain(".bar { fill: green; }")

      # Count occurrences of <rect to ensure 3 bars
      svg.scan(/<rect /).size.should eq(3)

      # Chart height = 120 - (2*10) = 100. Max count is 20.
      # Bar 1 (count 10): height = (10/20) * 100 = 50
      # Bar 2 (count 20): height = (20/20) * 100 = 100
      # Bar 3 (count 5):  height = (5/20) * 100 = 25
      svg.should contain("height=\"50.0\"")
      svg.should contain("height=\"100.0\"")
      svg.should contain("height=\"25.0\"")

      svg.should contain("<title>2023-01-01 10:00: 10</title>")
      svg.should contain("<title>2023-01-01 11:00: 20</title>")
      svg.should contain("<title>2023-01-01 12:00: 5</title>")
    end

    it "handles zero counts correctly, avoiding division by zero" do
      data = [
        {start_time: Time.utc(2023, 1, 1, 10), count: 0_i32},
        {start_time: Time.utc(2023, 1, 1, 11), count: 0_i32},
      ]
      svg = Timeline.generate_svg_timeline(data, width: 200, height: 100, padding: 10)
      # Max_count becomes 1.0 to avoid division by zero. Bar heights should be 0.
      svg.should contain("height=\"0.0\"") # Both bars should have 0 height
      svg.scan(/height=\"0.0\"/).size.should eq(2)
    end

    it "uses default parameter values if not provided" do
      data = [{start_time: Time.utc(2023, 1, 1, 10), count: 1_i32}]
      svg = Timeline.generate_svg_timeline(data) # Use all defaults

      # Check for default width, height, bar_color
      svg.should contain("viewBox=\"0 0 800 100\"")   # Default width 800, height 100
      svg.should contain(".bar { fill: steelblue; }") # Default bar_color
      # Default padding is 10. Chart height = 100 - 20 = 80. Bar height = (1/1)*80 = 80
      svg.should contain("height=\"80.0\"")
    end
  end
end
