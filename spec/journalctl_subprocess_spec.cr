require "./spec_helper"
require "log/spec"

# Exercises the REAL subprocess path (#61): Journalctl.query spawns
# the `journalctl` binary from PATH, and the fixture fake emits
# canned journal JSON so the spawn/parse/exit-status logic is
# observable. The duplicated-wait regression (#46) shipped in two
# releases because this path was dark. Plain builds only: demo
# builds compile the fixture-data branch instead of this code.
{% unless flag?(:demo_mode) %}
  describe "Journalctl.query (real subprocess path)" do
    fixture_dir = File.join(__DIR__, "fixtures")
    original_path = ENV["PATH"]

    around_each do |example|
      ENV["PATH"] = "#{fixture_dir}:#{original_path}"
      example.run
      ENV["PATH"] = original_path
    ensure
      ENV["PATH"] = original_path
    end

    it "parses the subprocess output into log entries" do
      entries = Journalctl.query || [] of Journalctl::LogEntry
      entries.size.should eq(2)
      entries.first.message_raw.should eq("spec log entry two")
      entries.last.message_raw.should eq("spec log entry one")
    end

    it "returns the parsed entries even when journalctl exits non-zero" do
      ENV["FAKE_EXIT_CODE"] = "1"
      entries = Journalctl.query || [] of Journalctl::LogEntry
      entries.size.should eq(2)
    ensure
      ENV.delete("FAKE_EXIT_CODE")
    end

    it "finds a context entry by cursor through the subprocess" do
      context_entries = Journalctl.context("spec-cursor-0001", 1)
      context_entries.should_not be_nil
      context = context_entries.not_nil!
      context.any? { |entry| entry.message_raw == "spec log entry one" }.should be_true
    end
  end
{% end %}
