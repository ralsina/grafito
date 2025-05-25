require "json"
require "time"
require "log"

# A wrapper for journalctl
class Journalctl
  # Setup a logger for this class
  Log = ::Log.for(self)

  # Represents a single log entry retrieved from journalctl.
  #
  # This class is used to parse and serialize log data.
  # It includes `JSON::Serializable` to allow easy conversion to and from JSON.
  class LogEntry
    include JSON::Serializable

    # Define the fields that will be serialized to JSON
    @[JSON::Field(key: "__REALTIME_TIMESTAMP")]
    property timestamp : String
    @[JSON::Field(key: "MESSAGE")]
    property message : String

    def to_s
      "#{@timestamp} - #{@message}"
    end

    # Converts the raw timestamp string to a formatted date/time string.
    # Example format: "2023-10-27 15:04:05.123"
    def formatted_timestamp(format = "%Y-%m-%d %H:%M:%S.%L") : String
      # __REALTIME_TIMESTAMP is in microseconds since epoch
      time_obj = Time.unix_ms(@timestamp.to_i64 // 1000)
      time_obj.to_s(format)
    rescue ex : ArgumentError # Catch potential errors from to_i64 if timestamp is not a valid number
      Journalctl::Log.warn(exception: ex) { "Failed to parse timestamp: '#{@timestamp}'" }
      "Invalid Timestamp"
    end
  end

  # Builds the journalctl command array based on the provided filters.
  # This is a private helper method.
  def self.build_query_command(
    since : String | Nil,
    unit : String | Nil,
    tag : String | Nil,
    query : String | Nil
  ) : Array(String)
    command = ["journalctl", "-o", "json", "-n", "5000", "-r"]

    if since
      command << "-S" << since
    end

    if unit
      command << "-u" << unit
    end

    if tag
      command << "-t" << tag
    end

    if query
      command << "-g" << query
    end
    command
  end

  # Queries the logs based on the provided criteria.
  #
  # Args:
  #   since: A time offset, like -15m or nil for no filter
  #   unit: The systemd unit to filter by (e.g., "nginx.service").
  #   tag:  The syslog identifier (tag) to filter by.
  #   live: A boolean indicating if the logs should be streamed live (not implemented yet).
  #   query: A string to filter logs by a specific search term.
  #
  # Returns:
  #   An array of LogEntry
  def self.query(
    since : String | Nil = nil,
    unit : String | Nil = nil,
    tag : String | Nil = nil,
    query : String | Nil = nil,
  ) : Array(LogEntry) | Nil
    Log.debug { "Executing Journalctl.query with arguments:" }
    Log.debug { "  Since: #{since.inspect}" }
    Log.debug { "  Unit: #{unit.inspect}" }
    Log.debug { "  Tag: #{tag.inspect}" }
    Log.debug { "  Query: #{query.inspect}" }

    # Treat empty string parameters for unit and tag as nil
    unit = nil if unit.is_a?(String) && unit.strip.empty?
    tag = nil if tag.is_a?(String) && tag.strip.empty?
    query = nil if query.is_a?(String) && query.strip.empty?

    command = build_query_command(since, unit, tag, query)
    Log.debug { "Generated journalctl command: #{command.inspect}" }
    # Execute the command and capture the output.
    stdout = IO::Memory.new
    result = Process.run(
      command[0],
      args: command[1..],
      output: stdout,
    )
    if result.normal_exit?
      log_entries = stdout.to_s.split("\n").compact_map do |line|
        next if line.strip.empty? # Skip empty or whitespace-only lines
        begin
          LogEntry.from_json(line) if line && !line.empty?
        rescue ex : JSON::ParseException
          Log.warn(exception: ex) { "Failed to parse log line: #{line.inspect}" }
          nil # Skip entries that fail to parse
        end
      end

      Log.debug { "Returning #{log_entries.size} log entries." }
      log_entries # journalctl has already filtered if query was provided
    else
      # Log an error if journalctl command failed
      Log.error { "journalctl command failed with exit code: #{result}. Stdout: #{stdout.to_s[0..100]}" }
      Log.debug { "Returning 0 log entries due to command failure." }
      nil # Explicitly return nil on failure
    end
  rescue ex
    Log.error(exception: ex) { "Error executing journalctl. Result code: #{result rescue "unknown"}" }
    Log.debug { "Returning 0 log entries due to an exception." }
    nil
  end

  # Retrieves a list of all known systemd service units using systemctl.
  #
  # Returns:
  #   An Array(String) containing unique service unit names, sorted, or nil if an error occurs.
  def self.known_service_units : Array(String) | Nil
    Log.debug { "Executing Journalctl.known_service_units" }
    # Using systemctl to list service units.
    # --type=service: Only list service units.
    # --all: Show all loaded units, including inactive ones.
    # --no-legend: Suppress the legend header and footer.
    # --plain: Output a plain list without ANSI escape codes or truncation.
    command = ["systemctl", "list-units", "--type=service", "--all", "--no-legend", "--plain"]

    Log.debug { "Generated systemctl command: #{command.inspect}" }

    stdout = IO::Memory.new
    result = Process.run(
      command[0],
      args: command[1..],
      output: stdout,
    )

    if result.normal_exit?
      known_units = Set(String).new
      stdout.to_s.split("\n").each do |line|
        next if line.strip.empty? # Skip empty or whitespace-only lines
        # The first word on each line should be the unit name.
        unit_name = line.split(" ").first?
        known_units.add(unit_name) if unit_name
      end
      Log.debug { "Found #{known_units.size} unique service units." }
      known_units.to_a.sort
    else
      Log.error { "systemctl command failed with exit code: #{result}. Stdout: #{stdout.to_s[0..100]}" }
      nil
    end
  rescue ex
    Log.error(exception: ex) { "Error executing systemctl for known_service_units." }
    nil
  end
end
