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
      entries.first.message_raw.should eq("spec log entry two\ncontinued after a blank-ish gap")
      entries.last.message_raw.should eq("spec log entry one")
    end

    it "logs a warning when journalctl exits non-zero" do
      ENV["FAKE_EXIT_CODE"] = "1"
      backend = Log::MemoryBackend.new
      Log.builder.bind("*", :warn, backend)
      begin
        Journalctl.query
      ensure
        Log.builder.unbind("*", :warn, backend)
        ENV.delete("FAKE_EXIT_CODE")
      end
      warnings = backend.entries.select(&.severity.warn?).map(&.message)
      warnings.join("\n").should contain("exited with 1")
    end

    it "streams multi-line messages without breaking SSE frames" do
      response = dispatch_request("GET", "/logs/stream?col-visible-message=on")

      response[:status].should eq(200)
      body = decode_chunked(response[:body])
      body.scan("event: log").size.should eq(2)

      # Two rows: a single-line row emits one `data:` line; the
      # multi-line row emits one per source line — the client joins
      # them back with newlines, so nothing is lost.
      data_lines = body.split("\n").select(&.starts_with?("data: "))
      data_lines.size.should eq(3)
      data_lines.any?(&.includes?("spec log entry two")).should be_true
      data_lines.any?(&.includes?("continued after a blank-ish gap")).should be_true
    end

    it "does not warn when journalctl exits cleanly" do
      backend = Log::MemoryBackend.new
      Log.builder.bind("*", :warn, backend)
      begin
        Journalctl.query
      ensure
        Log.builder.unbind("*", :warn, backend)
      end
      backend.entries.select(&.severity.warn?).size.should eq(0)
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
      context = context_entries || [] of Journalctl::LogEntry
      context.any? { |entry| entry.message_raw == "spec log entry one" }.should be_true
    end
  end
{% end %}

# The SSE route streams with chunked transfer encoding (no
# content-length), and dispatch_request strips only the head — so the
# framing spec decodes the chunks itself before asserting on events.
private def decode_chunked(raw : String) : String
  io = IO::Memory.new(raw)
  out_io = IO::Memory.new
  loop do
    size_line = io.gets(chomp: true)
    break if size_line.nil? || size_line.empty?
    size = size_line.to_i?(16)
    next if size.nil? # stray line
    break if size.zero?
    out_io << io.read_string(size)
    io.read_string(2) # trailing CRLF
  end
  out_io.to_s
end
