require "spec"
require "../src/fake_journal_data" # Access to the module being tested

# Helper to check if entries are sorted chronologically
def chronologically_sorted?(entries : Array(Journalctl::LogEntry))
  return true if entries.size < 2
  entries.each_cons(2).all? { |a| a[0].timestamp <= a[1].timestamp }
end

# Helper to check if entries are sorted reverse-chronologically
def reverse_chronologically_sorted?(entries : Array(Journalctl::LogEntry))
  return true if entries.size < 2
  entries.each_cons(2).all? { |a| a[0].timestamp >= a[1].timestamp }
end

describe FakeJournalData do
  describe ".parse_time_option" do
    # Define a fixed base time for consistent test results.
    # The method defaults to Time.utc if not provided, so we'll use UTC for clarity.
    base_time = Time.utc(2023, 10, 26, 12, 0, 0) # A Thursday

    context "with negative offsets (in the past)" do
      it "parses -Xm (minutes)" do
        result = FakeJournalData.parse_time_option("-30m", base_time)
        result.should eq(base_time - 30.minutes)
      end

      it "parses -Xh (hours)" do
        result = FakeJournalData.parse_time_option("-2h", base_time)
        result.should eq(base_time - 2.hours)
      end

      it "parses -Xd (days)" do
        result = FakeJournalData.parse_time_option("-3d", base_time)
        result.should eq(base_time - 3.days)
      end

      it "parses -XM (months, as value * 30 days)" do
        result = FakeJournalData.parse_time_option("-1M", base_time)
        result.should eq(base_time - 30.days) # 1 * 30 days
        result_2m = FakeJournalData.parse_time_option("-2M", base_time)
        result_2m.should eq(base_time - 60.days) # 2 * 30 days
      end

      it "parses -Xy (years, as value * 365 days)" do
        result = FakeJournalData.parse_time_option("-1y", base_time)
        result.should eq(base_time - 365.days) # 1 * 365 days
      end
    end

    context "with positive offsets (in the future, explicit '+')" do
      it "parses +Xm (minutes)" do
        result = FakeJournalData.parse_time_option("+15m", base_time)
        result.should eq(base_time + 15.minutes)
      end

      it "parses +Xh (hours)" do
        result = FakeJournalData.parse_time_option("+1h", base_time)
        result.should eq(base_time + 1.hour)
      end

      it "parses +Xd (days)" do
        result = FakeJournalData.parse_time_option("+7d", base_time)
        result.should eq(base_time + 7.days)
      end
    end

    context "with positive offsets (in the future, implicit sign)" do
      it "parses Xm (minutes) as positive" do
        result = FakeJournalData.parse_time_option("10m", base_time)
        result.should eq(base_time + 10.minutes)
      end

      it "parses Xd (days) as positive" do
        result = FakeJournalData.parse_time_option("1d", base_time)
        result.should eq(base_time + 1.day)
      end
    end

    context "with zero value offsets" do
      it "parses -0m, +0d, 0h, 0M, 0y correctly" do
        FakeJournalData.parse_time_option("-0m", base_time).should eq(base_time)
        FakeJournalData.parse_time_option("+0d", base_time).should eq(base_time)
        FakeJournalData.parse_time_option("0h", base_time).should eq(base_time)
        FakeJournalData.parse_time_option("0M", base_time).should eq(base_time)
        FakeJournalData.parse_time_option("0y", base_time).should eq(base_time)
      end
    end

    context "with different relative_to time" do
      custom_relative_time = Time.utc(2024, 1, 1, 0, 0, 0)
      it "calculates offset from the provided relative_to time" do
        result = FakeJournalData.parse_time_option("-1h", custom_relative_time)
        result.should eq(custom_relative_time - 1.hour)
      end
    end

    context "with invalid or unparseable inputs" do
      it "returns nil for unsupported units (e.g., weeks 'w', seconds 's')" do
        FakeJournalData.parse_time_option("-1w", base_time).should be_nil
        FakeJournalData.parse_time_option("-1s", base_time).should be_nil
      end

      it "returns nil for incorrect unit casing (e.g., 'H' for hours)" do
        FakeJournalData.parse_time_option("-1H", base_time).should be_nil # Expects 'h'
        FakeJournalData.parse_time_option("-1D", base_time).should be_nil # Expects 'd'
      end

      it "returns nil for malformed strings" do
        FakeJournalData.parse_time_option("invalid-string", base_time).should be_nil
        FakeJournalData.parse_time_option("-m", base_time).should be_nil      # Missing number
        FakeJournalData.parse_time_option("h", base_time).should be_nil       # Missing number and sign
        FakeJournalData.parse_time_option("10", base_time).should be_nil      # Missing unit
        FakeJournalData.parse_time_option("-", base_time).should be_nil       # Sign only
        FakeJournalData.parse_time_option("1.5h", base_time).should be_nil    # Decimal not supported
        FakeJournalData.parse_time_option("  -1h  ", base_time).should be_nil # Leading/trailing spaces not handled by regex
      end
    end
  end

  describe ".fake_run_journalctl_and_parse" do
    dummy_context_message = "test_fake_run"

    context "with no arguments" do
      it "generates a default number of log entries in chronological order" do
        entries = FakeJournalData.fake_run_journalctl_and_parse([] of String, dummy_context_message)
        # Default target_n_entries is 5000, num_entries_to_generate is rand(50..250)
        entries.size.should be > 50
        entries.size.should be < 250
        chronologically_sorted?(entries).should be_true
      end
    end

    context "with -n (number of entries) argument" do
      it "generates up to N entries if N is small and positive" do
        n_val = 10
        args = ["-n", n_val.to_s]
        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)
        entries.size.should be <= n_val
      end

      it "generates between 50 and 250 entries if N is large" do
        args = ["-n", "10000"] # Large N
        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)
        entries.size.should be >= 50
        entries.size.should be <= 250
      end
    end

    context "with -r (reverse order) argument" do
      it "generates entries in reverse chronological order" do
        args = ["-r", "-n", "20"] # Small n for easier check
        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)
        entries.should_not be_empty
        reverse_chronologically_sorted?(entries).should be_true
      end
    end

    context "with -p (priority) argument" do
      it "generates entries with priority less than or equal to the specified value" do
        max_prio = 3
        args = ["-p", max_prio.to_s, "-n", "20"]
        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)

        # It's possible that with very restrictive filters and few attempts, no entries are generated.
        # If entries are generated, they must adhere to the filter.
        unless entries.empty?
          entries.each do |entry|
            entry.raw_priority_val.try(&.to_i.should be <= max_prio)
          end
        end
      end
    end

    context "with -u (unit) argument" do
      it "generates entries for the specified unit if entries are produced" do
        target_unit_name = "nginx.service"
        args = ["-u", target_unit_name, "-n", "20"]
        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)
        unless entries.empty?
          entries.each do |entry|
            entry.internal_unit_name.should eq target_unit_name
          end
        end
      end
    end

    context "with -t (include tag) arguments" do
      it "generates entries matching one of the specified syslog identifiers if entries are produced" do
        # cron.service -> cron, myapp.service -> myapp
        tag_to_include1 = "cron"
        tag_to_include2 = "myapp"
        # Ensure these units can be generated by adding them via -u, then filter with -t
        # This is a bit of a combined test. A pure -t test relies on random unit generation.
        args = ["-t", tag_to_include1, "-t", tag_to_include2, "-n", "30"]

        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)
        unless entries.empty?
          entries.each do |entry|
            entry_tag = entry.data["SYSLOG_IDENTIFIER"].to_s
            ([tag_to_include1, tag_to_include2].includes?(entry_tag)).should be_true
          end
        end
      end
    end

    context "with -T (exclude tag) argument" do
      it "generates entries not matching the specified syslog identifier if entries are produced" do
        tag_to_exclude = "cron" # from cron.service
        # We will also pass -u with a different service to ensure some logs are generated
        args = ["-u", "nginx.service", "-T", tag_to_exclude, "-n", "20"]
        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)
        unless entries.empty?
          entries.each do |entry|
            entry_tag = entry.data["SYSLOG_IDENTIFIER"].to_s
            entry_tag.should_not eq tag_to_exclude
          end
        end
      end
    end

    context "with --cursor argument" do
      it "uses the provided cursor in generated entries" do
        custom_cursor = "my_special_cursor_123"
        args = ["--cursor", custom_cursor, "-n", "5"]
        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)
        entries.should_not be_empty
        entries.each do |entry|
          entry.data["__CURSOR"].should eq custom_cursor
        end
      end
    end

    context "with time arguments -S (since) and --until" do
      # Note: Time.local is used internally. Tests assume execution is quick.
      # A more robust test would involve injecting Time.
      it "generates entries within the specified time window" do
        current_test_time = Time.local # Approximate time of internal call

        since_arg = "-30m"
        until_arg = "-10m" # 10 minutes ago from current_test_time
        args = ["-S", since_arg, "--until", until_arg, "-n", "15"]

        expected_start_time = FakeJournalData.parse_time_option(since_arg, current_test_time).as(Time)
        expected_end_time = FakeJournalData.parse_time_option(until_arg, current_test_time).as(Time)

        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)

        # Allow for a small buffer due to Time.local being called at different points.
        # The internal start_time/end_time are what matter.
        time_buffer = 1.second

        unless entries.empty?
          entries.each do |entry|
            entry.timestamp.should be >= (expected_start_time - time_buffer)
            entry.timestamp.should be <= (expected_end_time + time_buffer)
          end
        end
      end

      it "handles 'since' after 'until' by using 'until' time for both" do
        current_test_time = Time.local
        since_arg = "-10m" # More recent
        until_arg = "-30m" # Older
        args = ["-S", since_arg, "--until", until_arg, "-n", "5"]

        # Expected behavior: start_time and end_time become the 'until' time.
        expected_time = FakeJournalData.parse_time_option(until_arg, current_test_time).as(Time)
        time_buffer = 1.second

        entries = FakeJournalData.fake_run_journalctl_and_parse(args, dummy_context_message)
        # In this case, start_unix_ms might equal end_unix_ms, so all timestamps should be very close.
        unless entries.empty?
          entries.each do |entry|
            (entry.timestamp - expected_time).abs.total_milliseconds.should be <= time_buffer.total_milliseconds
          end
        end
      end
    end
  end
end
