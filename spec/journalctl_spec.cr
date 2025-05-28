require "./spec_helper"

describe Journalctl::LogEntry do
  describe ".from_json" do
    context "when parsing a standard journalctl JSON line" do
      # Sample JSON output from journalctl -o json
      # Note: journalctl outputs one JSON object per line, not a single array.
      json_line = %({
          "__REALTIME_TIMESTAMP" : "1678886400000000",
          "MESSAGE" : "This is a test log message.",
          "PRIORITY" : "6",
          "_SYSTEMD_UNIT" : "my-test-service.service",
          "SYSLOG_IDENTIFIER" : "test-tag",
          "CONTAINER_NAME" : "my-container",
          "SOME_NUMBER_FIELD" : "123",
          "SOME_BOOLEAN_FIELD" : "true",
          "SOME_NULL_FIELD" : null,
          "EMPTY_STRING_FIELD" : ""
        })

      it "correctly populates the data hash with all fields as strings" do
        entry = Journalctl::LogEntry.from_json(json_line)

        entry.data.should be_a(Hash(String, String))

        # Expected data hash based on the JSON and .to_s conversion
        expected_data = {
          "__REALTIME_TIMESTAMP" => "1678886400000000",
          "MESSAGE"              => "This is a test log message.",
          "PRIORITY"             => "6",
          "_SYSTEMD_UNIT"        => "my-test-service.service",
          "SYSLOG_IDENTIFIER"    => "test-tag",
          "CONTAINER_NAME"       => "my-container",
          "SOME_NUMBER_FIELD"    => "123",
          "SOME_BOOLEAN_FIELD"   => "true",
          "SOME_NULL_FIELD"      => "", # JSON null becomes "" via JSON::Any#to_s
          "EMPTY_STRING_FIELD"   => "",
        }

        entry.data.size.should eq(expected_data.size)

        expected_data.each do |key, expected_value|
          entry.data.keys.should contain(key)
          entry.data[key].should eq(expected_value)
          entry.data[key].should be_a(String) # Explicitly check type
        end
      end

      it "correctly populates the specific mapped properties" do
        entry = Journalctl::LogEntry.from_json(json_line)

        # Check the specific properties that are mapped
        entry.timestamp.should be_a(Time)
        # Check the timestamp value - 1678886400000000 us is 1678886400 s
        entry.timestamp.to_unix.should eq(1678886400)

        entry.message_raw.should eq("This is a test log message.")
        entry.message.should eq("[my-container]: This is a test log message.") # Check getter

        entry.raw_priority_val.should eq("6")
        entry.priority.should eq("6") # Check getter

        entry.internal_unit_name.should eq("my-test-service.service")
        entry.unit.should eq("my-test-service") # Check getter (strips .service)
      end

      it "handles missing optional fields gracefully" do
        json_line_missing_fields = %({
          "__REALTIME_TIMESTAMP" : "1678886401000000",
          "MESSAGE" : "Another message."
        }) # Missing PRIORITY, _SYSTEMD_UNIT, etc.

        entry = Journalctl::LogEntry.from_json(json_line_missing_fields)

        # Check that data hash still contains the fields that were present
        entry.data.keys.should contain("__REALTIME_TIMESTAMP")
        entry.data.keys.should contain("MESSAGE")
        entry.data.size.should eq(2) # Only the two fields present

        # Check that mapped properties for missing fields are nil or default
        entry.raw_priority_val.should be_nil
        entry.priority.should eq("7") # Default priority getter

        entry.internal_unit_name.should be_nil
        entry.unit.should eq("N/A") # Default unit getter

        # Check that timestamp and message are still correct
        entry.timestamp.to_unix.should eq(1678886401)
        entry.message_raw.should eq("Another message.")
      end
    end
  end
end
