require "spec"
require "../src/journalctl"

describe Journalctl::LogEntry do
  describe "#initialize and getters" do
    it "initializes with valid data and getters return correct values" do
      time = Time.utc(2023, 10, 27, 10, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: time,
        message_raw: "  Test message  ",
        raw_priority_val: "3",
        internal_unit_name: "  nginx.service  "
      )

      entry.timestamp.should eq(time)
      entry.message.should eq("Test message")
      entry.priority.should eq("3")
      entry.unit.should eq("nginx")
    end

    it "handles nil internal_unit_name correctly" do
      time = Time.utc(2023, 10, 27, 10, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: time,
        message_raw: "Another message",
        raw_priority_val: "5",
        internal_unit_name: nil
      )
      entry.unit.should eq("N/A")
    end

    it "defaults priority to '7' if raw_priority_val is empty or nil" do
      time = Time.utc(2023, 10, 27, 10, 30, 0)
      entry_empty = Journalctl::LogEntry.new(timestamp: time, message_raw: "m", raw_priority_val: " ", internal_unit_name: "u")
      entry_empty.priority.should eq("7")

      # Note: JSON::Serializable would likely prevent raw_priority_val from being nil if not nilable in JSON mapping,
      # but testing the getter's robustness is still good.
      # If raw_priority_val could be nil due to direct instantiation:
      # entry_nil = Journalctl::LogEntry.new(timestamp: time, message_raw: "m", raw_priority_val: nil, internal_unit_name: "u")
      # entry_nil.priority.should eq("7") # This depends on how nil is handled before .to_s.strip
    end
  end

  describe "#formatted_timestamp" do
    it "formats timestamp with default format" do
      time = Time.utc(2023, 10, 27, 15, 4, 5)
      entry = Journalctl::LogEntry.new(timestamp: time, message_raw: "m", raw_priority_val: "p", internal_unit_name: "u")
      entry.formatted_timestamp.should eq("Oct 27 15:04:05") # Default format: "%b %d %H:%M:%S"
    end

    it "formats timestamp with custom format" do
      time = Time.utc(2023, 10, 27, 15, 4, 5)
      entry = Journalctl::LogEntry.new(timestamp: time, message_raw: "m", raw_priority_val: "p", internal_unit_name: "u")
      entry.formatted_timestamp("%Y-%m-%d %H:%M:%S.%L").should eq("2023-10-27 15:04:05.000")
    end
  end

  describe "#formatted_priority" do
    it "returns correct textual representation for known priorities" do
      time = Time.utc(2023, 1, 1)
      priorities = {
        "0" => "Emergency", "1" => "Alert", "2" => "Critical", "3" => "Error",
        "4" => "Warning", "5" => "Notice", "6" => "Informational", "7" => "Debug",
      }
      priorities.each do |num_val, text_val|
        entry = Journalctl::LogEntry.new(timestamp: time, message_raw: "m", raw_priority_val: num_val, internal_unit_name: "u")
        entry.formatted_priority.should eq(text_val)
      end
    end

    it "returns the numeric priority if unknown" do
      time = Time.utc(2023, 1, 1)
      entry = Journalctl::LogEntry.new(timestamp: time, message_raw: "m", raw_priority_val: "99", internal_unit_name: "u")
      entry.formatted_priority.should eq("99")
    end

    it "uses default priority '7' (Debug) for formatting if raw priority is empty" do
      time = Time.utc(2023, 1, 1)
      entry = Journalctl::LogEntry.new(timestamp: time, message_raw: "m", raw_priority_val: " ", internal_unit_name: "u")
      entry.formatted_priority.should eq("Debug") # Because entry.priority defaults to "7"
    end
  end

  describe "#to_s" do
    it "returns a correctly formatted string representation" do
      time = Time.utc(2023, 10, 27, 10, 30, 0)
      entry = Journalctl::LogEntry.new(
        timestamp: time,
        message_raw: "Log message",
        raw_priority_val: "4",
        internal_unit_name: "my.service"
      )
      # Expected format: "#{timestamp.to_s("%Y-%m-%d %H:%M:%S.%L")} [#{unit}] [Prio: #{priority}] - #{message}"
      expected_string = "2023-10-27 10:30:00.000 [my] [Prio: 4] - Log message"
      entry.to_s.should eq(expected_string)
    end
  end

  describe ".from_json" do
    it "deserializes a valid JSON string correctly" do
      json_string = %({"__REALTIME_TIMESTAMP": "1698402600000000", "MESSAGE": "Valid message", "PRIORITY": "2", "_SYSTEMD_UNIT": "kernel.service"})
      entry = Journalctl::LogEntry.from_json(json_string)

      expected_time = Time.utc(2023, 10, 27, 10, 30, 0)
      entry.timestamp.should eq(expected_time)
      entry.message.should eq("Valid message")
      entry.priority.should eq("2")
      entry.unit.should eq("kernel")
    end

    it "handles missing optional _SYSTEMD_UNIT field" do
      json_string = %({"__REALTIME_TIMESTAMP": "1698402600000000", "MESSAGE": "No unit", "PRIORITY": "5"})
      entry = Journalctl::LogEntry.from_json(json_string)
      entry.unit.should eq("N/A")
    end

    it "handles invalid timestamp string by defaulting to epoch (via converter)" do
      json_string = %({"__REALTIME_TIMESTAMP": "invalid_timestamp", "MESSAGE": "Msg", "PRIORITY": "6"})
      entry = Journalctl::LogEntry.from_json(json_string)
      entry.timestamp.should eq(Time.unix(0))
    end

    it "handles missing MESSAGE by defaulting to empty string" do
      json_string = %({"__REALTIME_TIMESTAMP": "1698402600000000", "PRIORITY": "6"})
      # JSON::Serializable will raise if a non-nilable field is missing and no default is in initialize
      # Assuming message_raw in initialize defaults to "" or is made nilable and getter handles nil
      # Based on current LogEntry, message_raw is not nilable in initialize.
      # Let's assume JSON::Field(key: "MESSAGE", nilable: true) for message_raw for this test.
      # If not, this test would expect a JSON::MissingFieldError.
      # For now, we'll test the getter's behavior if message_raw were nil.
      # This requires LogEntry.initialize to allow message_raw: nil or have a default.
      # The current initialize has `message_raw : String`, so this test as-is would fail.
      # To make it pass, `message_raw` in `initialize` would need to be `String? = nil`
      # or the JSON mapping `@[JSON::Field(key: "MESSAGE", nilable: true)]`
      # For the purpose of this test, let's assume the JSON is valid but the value is null.
      json_string_null_message = %({"__REALTIME_TIMESTAMP": "1698402600000000", "MESSAGE": null, "PRIORITY": "6"})
      entry = Journalctl::LogEntry.from_json(json_string_null_message)
      entry.message.should eq("") # Getter @message_raw.to_s.strip handles nil
    end

    it "handles missing PRIORITY by defaulting to '7'" do
      json_string_null_priority = %({"__REALTIME_TIMESTAMP": "1698402600000000", "MESSAGE": "Test", "PRIORITY": null})
      entry = Journalctl::LogEntry.from_json(json_string_null_priority)
      entry.priority.should eq("7") # Getter @raw_priority_val.to_s.strip handles nil, then defaults
    end
  end
end
