require "../src/journalctl"
require "../src/grafito"
require "spec"

describe "Timezone Support" do
  describe "LogEntry#formatted_timestamp_with_timezone" do
    it "formats timestamp with local timezone by default" do
      # Create a time in UTC for consistent testing
      utc_time = Time.utc(2023, 11, 17, 14, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: utc_time,
        message_raw: "Test message",
        raw_priority_val: "6",
        internal_unit_name: "test.service"
      )

      # Set timezone to local
      Grafito.timezone = "local"

      # Should return a formatted timestamp (exact value depends on system timezone)
      result = entry.formatted_timestamp_with_timezone
      result.should match(/^\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/) # MM-DD HH:MM:SS format
    end

    it "formats timestamp with UTC timezone" do
      utc_time = Time.utc(2023, 11, 17, 14, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: utc_time,
        message_raw: "Test message",
        raw_priority_val: "6",
        internal_unit_name: "test.service"
      )

      # Set timezone to UTC
      Grafito.timezone = "utc"

      result = entry.formatted_timestamp_with_timezone
      result.should eq("11-17 14:30:00") # Should match UTC time
    end

    it "formats timestamp with GMT offset" do
      utc_time = Time.utc(2023, 11, 17, 14, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: utc_time,
        message_raw: "Test message",
        raw_priority_val: "6",
        internal_unit_name: "test.service"
      )

      # Set timezone to GMT+5 (5 hours ahead of UTC)
      Grafito.timezone = "GMT+5"

      result = entry.formatted_timestamp_with_timezone
      result.should eq("11-17 19:30:00") # UTC + 5 hours = 19:30
    end

    it "formats timestamp with negative GMT offset" do
      utc_time = Time.utc(2023, 11, 17, 14, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: utc_time,
        message_raw: "Test message",
        raw_priority_val: "6",
        internal_unit_name: "test.service"
      )

      # Set timezone to GMT-3 (3 hours behind UTC)
      Grafito.timezone = "GMT-3"

      result = entry.formatted_timestamp_with_timezone
      result.should eq("11-17 11:30:00") # UTC - 3 hours = 11:30
    end

    it "formats timestamp with custom format" do
      utc_time = Time.utc(2023, 11, 17, 14, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: utc_time,
        message_raw: "Test message",
        raw_priority_val: "6",
        internal_unit_name: "test.service"
      )

      Grafito.timezone = "utc"

      # Test custom format
      result = entry.formatted_timestamp_with_timezone("%Y-%m-%d %H:%M:%S")
      result.should eq("2023-11-17 14:30:00")
    end

    it "handles invalid timezone gracefully" do
      utc_time = Time.utc(2023, 11, 17, 14, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: utc_time,
        message_raw: "Test message",
        raw_priority_val: "6",
        internal_unit_name: "test.service"
      )

      # Set invalid timezone
      Grafito.timezone = "Invalid/Timezone"

      # Should fall back to local time without crashing
      result = entry.formatted_timestamp_with_timezone
      result.should match(/^\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/)
    end

    it "handles GMT offset with minutes" do
      utc_time = Time.utc(2023, 11, 17, 14, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: utc_time,
        message_raw: "Test message",
        raw_priority_val: "6",
        internal_unit_name: "test.service"
      )

      # Set timezone to GMT+5:30 (5 hours 30 minutes ahead of UTC)
      Grafito.timezone = "GMT+5:30"

      result = entry.formatted_timestamp_with_timezone
      result.should eq("11-17 20:00:00") # UTC + 5:30 hours = 20:00
    end
  end

  # Reset timezone after tests
  after_all do
    Grafito.timezone = "local"
  end
end
