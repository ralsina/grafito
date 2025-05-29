describe "_generate_text_log_output" do
  it "handles empty logs" do
    logs = [] of Journalctl::LogEntry
    output = Grafito._generate_text_log_output(logs)
    output.should eq("No log entries found.\n")
  end

  it "formats a single log entry including its message" do
    entry_time = Time.utc(2023, 10, 26, 12, 30, 0)
    logs = [new_log_entry(message: "Test message 1", priority: "6", unit: "unit1.service", timestamp: entry_time)]
    output = Grafito._generate_text_log_output(logs)
    # Note: LogEntry#formatted_timestamp depends on LogEntry's implementation.
    # This test assumes the message is part of the output.
    # Based on typical log formats, including the message is expected.
    expected_ts = logs[0].formatted_timestamp
    output.should eq("#{expected_ts} [unit1] (Informational) Test message 1\n")
  end

  it "formats multiple log entries" do
    time1 = Time.utc(2023, 10, 26, 12, 30, 0)
    time2 = Time.utc(2023, 10, 26, 12, 31, 0)
    logs = [new_log_entry(message: "Message A", priority: "6", unit: "unitA.service", timestamp: time1),
            new_log_entry(message: "Message B", priority: "3", unit: "unitB.service", timestamp: time2),
    ]
    output = Grafito._generate_text_log_output(logs)
    ts1 = logs[0].formatted_timestamp
    ts2 = logs[1].formatted_timestamp
    expected_output = "#{ts1} [unitA] (Informational) Message A\n" +
                      "#{ts2} [unitB] (Error) Message B\n"
    output.should eq(expected_output)
  end
end
