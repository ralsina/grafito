require "spec"
require "../src/fake_journal_data" # Access to the module being tested

describe FakeJournalData do
  describe ".parse_journalctl_time_string" do
    # Define a fixed base time for consistent test results.
    # The method defaults to Time.utc if not provided, so we'll use UTC for clarity.
    base_time = Time.utc(2023, 10, 26, 12, 0, 0) # A Thursday

    context "with negative offsets (in the past)" do
      it "parses -Xm (minutes)" do
        result = FakeJournalData.parse_journalctl_time_string("-30m", base_time)
        result.should eq(base_time - 30.minutes)
      end

      it "parses -Xh (hours)" do
        result = FakeJournalData.parse_journalctl_time_string("-2h", base_time)
        result.should eq(base_time - 2.hours)
      end

      it "parses -Xd (days)" do
        result = FakeJournalData.parse_journalctl_time_string("-3d", base_time)
        result.should eq(base_time - 3.days)
      end

      it "parses -XM (months, as value * 30 days)" do
        result = FakeJournalData.parse_journalctl_time_string("-1M", base_time)
        result.should eq(base_time - 30.days) # 1 * 30 days
        result_2m = FakeJournalData.parse_journalctl_time_string("-2M", base_time)
        result_2m.should eq(base_time - 60.days) # 2 * 30 days
      end

      it "parses -Xy (years, as value * 365 days)" do
        result = FakeJournalData.parse_journalctl_time_string("-1y", base_time)
        result.should eq(base_time - 365.days) # 1 * 365 days
      end
    end

    context "with positive offsets (in the future, explicit '+')" do
      it "parses +Xm (minutes)" do
        result = FakeJournalData.parse_journalctl_time_string("+15m", base_time)
        result.should eq(base_time + 15.minutes)
      end

      it "parses +Xh (hours)" do
        result = FakeJournalData.parse_journalctl_time_string("+1h", base_time)
        result.should eq(base_time + 1.hour)
      end

      it "parses +Xd (days)" do
        result = FakeJournalData.parse_journalctl_time_string("+7d", base_time)
        result.should eq(base_time + 7.days)
      end
    end

    context "with positive offsets (in the future, implicit sign)" do
      it "parses Xm (minutes) as positive" do
        result = FakeJournalData.parse_journalctl_time_string("10m", base_time)
        result.should eq(base_time + 10.minutes)
      end

      it "parses Xd (days) as positive" do
        result = FakeJournalData.parse_journalctl_time_string("1d", base_time)
        result.should eq(base_time + 1.day)
      end
    end

    context "with zero value offsets" do
      it "parses -0m, +0d, 0h, 0M, 0y correctly" do
        FakeJournalData.parse_journalctl_time_string("-0m", base_time).should eq(base_time)
        FakeJournalData.parse_journalctl_time_string("+0d", base_time).should eq(base_time)
        FakeJournalData.parse_journalctl_time_string("0h", base_time).should eq(base_time)
        FakeJournalData.parse_journalctl_time_string("0M", base_time).should eq(base_time)
        FakeJournalData.parse_journalctl_time_string("0y", base_time).should eq(base_time)
      end
    end

    context "with different relative_to time" do
      custom_relative_time = Time.utc(2024, 1, 1, 0, 0, 0)
      it "calculates offset from the provided relative_to time" do
        result = FakeJournalData.parse_journalctl_time_string("-1h", custom_relative_time)
        result.should eq(custom_relative_time - 1.hour)
      end
    end

    context "with invalid or unparseable inputs" do
      it "returns nil for unsupported units (e.g., weeks 'w', seconds 's')" do
        FakeJournalData.parse_journalctl_time_string("-1w", base_time).should be_nil
        FakeJournalData.parse_journalctl_time_string("-1s", base_time).should be_nil
      end

      it "returns nil for incorrect unit casing (e.g., 'H' for hours)" do
        FakeJournalData.parse_journalctl_time_string("-1H", base_time).should be_nil # Expects 'h'
        FakeJournalData.parse_journalctl_time_string("-1D", base_time).should be_nil # Expects 'd'
      end

      it "returns nil for malformed strings" do
        FakeJournalData.parse_journalctl_time_string("invalid-string", base_time).should be_nil
        FakeJournalData.parse_journalctl_time_string("-m", base_time).should be_nil      # Missing number
        FakeJournalData.parse_journalctl_time_string("h", base_time).should be_nil       # Missing number and sign
        FakeJournalData.parse_journalctl_time_string("10", base_time).should be_nil      # Missing unit
        FakeJournalData.parse_journalctl_time_string("-", base_time).should be_nil       # Sign only
        FakeJournalData.parse_journalctl_time_string("1.5h", base_time).should be_nil    # Decimal not supported
        FakeJournalData.parse_journalctl_time_string("  -1h  ", base_time).should be_nil # Leading/trailing spaces not handled by regex
      end
    end
  end
end
