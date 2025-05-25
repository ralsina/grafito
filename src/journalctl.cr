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
    @[JSON::Field(key: "PRIORITY")]
    property priority : String
    @[JSON::Field(key: "_SYSTEMD_UNIT")]
    property service : String? # Can be nil if not present for a log entry

    def initialize(
      timestamp : String | JSON::Any | Nil = nil,
      message : String | JSON::Any | Nil = nil,
      priority : String | JSON::Any | Nil = nil,
      service : String | JSON::Any | Nil = nil,
    )
      @timestamp = (timestamp || "0").to_s.strip
      @message = (message || "").to_s.strip
      @priority = (priority || "7").to_s.strip # Default to "7" (debug) if not present
      @service = (service || "N/A").to_s.strip.gsub(/\.service$/, "") # Remove ".service" suffix if present
    end

    def to_s
      "#{@timestamp} [#{@service || "N/A"}] [Prio: #{@priority}] - #{@message}"
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

    # Converts the numeric priority string to its textual representation.
    def formatted_priority : String
      case @priority
      when "0" then "Emergency"
      when "1" then "Alert"
      when "2" then "Critical"
      when "3" then "Error"
      when "4" then "Warning"
      when "5" then "Notice"
      when "6" then "Informational"
      when "7" then "Debug"
      else
        # If priority is unknown or not a standard number, return the original value
        Journalctl::Log.debug { "Unknown priority value: '#{@priority}'" }
        @priority
      end
    end
  end

  # Builds the journalctl command array based on the provided filters.
  # This is a private helper method.
  def self.build_query_command(
    since : String | Nil,
    unit : String | Nil,
    tag : String | Nil,
    query : String | Nil,
    priority : String | Nil,
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

    if priority
      command << "-p" << priority
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
    priority : String | Nil = nil,
    sort_by : String | Nil = nil,
    sort_order : String | Nil = nil,
  ) : Array(LogEntry) | Nil
    Log.debug { "Executing Journalctl.query with arguments:" }
    Log.debug { "  Since: #{since.inspect}" }
    Log.debug { "  Unit: #{unit.inspect}" }
    Log.debug { "  Tag: #{tag.inspect}" }
    Log.debug { "  Query: #{query.inspect}" }
    Log.debug { "  Priority: #{priority.inspect}" }
    Log.debug { "  SortBy: #{sort_by.inspect}" }
    Log.debug { "  SortOrder: #{sort_order.inspect}" }

    # Treat empty string parameters for unit and tag as nil
    unit = nil if unit.is_a?(String) && unit.strip.empty?
    tag = nil if tag.is_a?(String) && tag.strip.empty?
    query = nil if query.is_a?(String) && query.strip.empty?
    priority = nil if priority.is_a?(String) && priority.strip.empty?
    command = build_query_command(since, unit, tag, query, priority)
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
          parsed_json = JSON.parse(line)
          LogEntry.new(
            timestamp: parsed_json["__REALTIME_TIMESTAMP"]?.to_s,
            message: parsed_json["MESSAGE"]?,
            priority: parsed_json["PRIORITY"]?,
            service: parsed_json["_SYSTEMD_UNIT"]?,
          )
        rescue ex : JSON::ParseException
          Log.warn(exception: ex) { "Failed to parse log line: #{line.inspect[..100]}" }
          next
        end
      end

      # Sort the entries if sort_by is provided
      if sort_by && log_entries
        is_ascending = sort_order.nil? || sort_order.downcase == "asc"
        Log.debug { "Sorting by '#{sort_by}', order: #{is_ascending ? "ASC" : "DESC"}" }

        log_entries.sort! do |a, b|
          cmp = 0
          case sort_by
          when "timestamp"
            # __REALTIME_TIMESTAMP is microseconds since epoch
            cmp = a.timestamp.to_i64 <=> b.timestamp.to_i64
          when "priority"
            # PRIORITY is a string "0".."7"
            cmp = a.priority.to_i <=> b.priority.to_i
          when "message"
            cmp = a.message.downcase <=> b.message.downcase
          else
            Log.warn { "Unknown sort_by key: #{sort_by}" }
            0 # Default to no change in order for unknown keys
          end
          is_ascending ? cmp : -cmp
        end
      else
        # If not sorting, journalctl -r already provides reverse chronological order (newest first)
        Log.debug { "No specific sorting requested, relying on journalctl default order (or no entries)." }
      end

      Log.debug { "Returning #{log_entries.try &.size.to_s || "0"} log entries." }
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
