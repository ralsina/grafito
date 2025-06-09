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

describe Journalctl do
  describe "#build_query_command" do
    context "when processing the query parameter" do
      it "passes queries like _FIELD=VALUE verbatim (e.g., _HOSTNAME=foobar)" do
        query_string = "_HOSTNAME=foobar"
        command = Journalctl.build_query_command(query: query_string)

        command.should contain(query_string)
        command.should_not contain("-g")
      end

      it "passes queries like FIELD=VALUE verbatim (e.g., FOOBAR=coocoo)" do
        query_string = "FOOBAR=coocoo"
        command = Journalctl.build_query_command(query: query_string)

        command.should contain(query_string)
        command.should_not contain("-g")
      end

      it "uses -g for general text queries" do
        query_string = "some generic error"
        command = Journalctl.build_query_command(query: query_string)

        command.should contain("-g")
        command.should contain(query_string)
      end

      it "uses -g for queries like field=value with lowercase field names" do
        query_string = "hostname=foobar" # lowercase 'hostname'
        command = Journalctl.build_query_command(query: query_string)

        command.should contain("-g")
        command.should contain(query_string)
      end

      it "handles queries with numbers and underscores in the FIELD name for verbatim pass" do
        query_string = "_SYSTEMD_UNIT_123=my.service"
        command = Journalctl.build_query_command(query: query_string)

        command.should contain(query_string)
        command.should_not contain("-g")
      end

      it "handles empty value in FIELD=VALUE query for verbatim pass" do
        query_string = "MY_VAR="
        command = Journalctl.build_query_command(query: query_string)

        command.should contain(query_string)
        command.should_not contain("-g")
      end

      it "returns a command without query parts if query is nil" do
        command = Journalctl.build_query_command(query: nil)
        command.should_not contain("-g")
        # Ensure no accidental FIELD=VALUE strings are present
        command.none? { |part| part.includes?("=") && part.matches?(/^_{0,1}[A-Z0-9_]+=.*$/) }.should be_true
      end
    end

    context "when combining query with other parameters" do
      it "correctly includes all parts for a verbatim query" do
        query_string = "_SYSTEMD_UNIT=test.service"
        command = Journalctl.build_query_command(
          query: query_string,
          lines: 100,
          priority: "err"
        )

        command.should contain(query_string)
        command.should_not contain("-g")
        command.should contain("-n")
        command.should contain("100")
        command.should contain("-p")
        command.should contain("err")
      end

      it "correctly includes all parts for a -g query" do
        query_string = "a general search"
        command = Journalctl.build_query_command(query: query_string, lines: 50)

        command.should contain("-g")
        command.should contain(query_string)
        command.should contain("-n")
        command.should contain("50")
      end
    end
  end
end
