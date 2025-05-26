require "json"
require "time"
require "log"

# A wrapper for journalctl
class Journalctl
  # Setup a logger for this class
  Log = ::Log.for(self)

  # Custom JSON converter for __REALTIME_TIMESTAMP (microseconds string) to Time
  class MicrosecondsEpochConverter
    def self.from_json(parser : JSON::PullParser) : Time
      s = parser.read_string # Read as nullable string
      if s.nil? || s.empty?
        # Log.warn { "Nil or empty timestamp string received, defaulting to epoch." } # Optional: for debugging
        return Time.unix(0) # Default to epoch for nil/empty string
      end
      Time.unix_ms(s.to_i64 // 1000)
    rescue ex : ArgumentError
      Journalctl::Log.warn(exception: ex) { "Failed to parse timestamp string '#{s}' for Time conversion, defaulting to epoch." }
      Time.unix(0) # Default to epoch on parsing error
    end

    def self.to_json(value : Time, builder : JSON::Builder)
      builder.string((value.to_unix_us).to_s)
    end
  end

  # Represents a single log entry retrieved from journalctl.
  #
  # This class is used to parse and serialize log data.
  # It includes `JSON::Serializable` to allow easy conversion to and from JSON.
  class LogEntry
    include JSON::Serializable
    # The __REALTIME_TIMESTAMP from journalctl is microseconds since epoch, as a string.
    @[JSON::Field(key: "__REALTIME_TIMESTAMP", converter: Journalctl::MicrosecondsEpochConverter)]
    property timestamp : Time

    @[JSON::Field(key: "MESSAGE")]
    property message_raw : String? # Raw message from JSON

    @[JSON::Field(key: "PRIORITY")]
    property raw_priority_val : String? # Raw priority string from JSON (e.g., "3")

    @[JSON::Field(key: "_SYSTEMD_UNIT", nilable: true)] # Allow nil from JSON
    property internal_unit_name : String?               # Raw unit name from JSON, might be nil

    # Constructor used by JSON::Serializable.
    # It's called with named arguments matching property names, after converters are applied.
    def initialize(
      @timestamp : Time,
      @message_raw : String,
      @raw_priority_val : String,
      @internal_unit_name : String? = nil, # Default to nil if _SYSTEMD_UNIT is missing
    )
      # Properties are assigned directly by JSON::Serializable
      # Stripping and defaulting are handled by getters below.
    end

    # Getter for the cleaned message
    def message : String
      @message_raw.to_s.strip
    end

    # Getter for the priority string (e.g., "0" to "7")
    # This maintains compatibility with previous direct `priority` field access.
    def priority : String
      val = @raw_priority_val.to_s.strip
      val.empty? ? "7" : val # Default to "7" (debug) if empty or not a standard number
    end

    # Getter for the cleaned unit name
    def unit : String
      (@internal_unit_name || "N/A").strip.gsub(/\.service$/, "")
    end

    def to_s
      # Use a standard timestamp format for to_s, and getters for other fields
      "#{timestamp.to_s("%Y-%m-%d %H:%M:%S.%L")} [#{unit}] [Prio: #{priority}] - #{message}"
    end

    # Converts the raw timestamp string to a formatted date/time string.
    # Example format: "2023-10-27 15:04:05.123"
    def formatted_timestamp(format = "%b %d %H:%M:%S") : String
      @timestamp.to_s(format) # @timestamp is now a Time object
    end

    # Converts the numeric priority string to its textual representation.
    def formatted_priority : String
      case self.priority # Use the getter to ensure defaulting/cleaning
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
        Journalctl::Log.debug { "Unknown priority value: '#{self.priority}'" }
        self.priority
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
      # Split the unit string into words and add -u for each word
      unit.split.each do |u_word|
        command << "-u" << u_word unless u_word.strip.empty? # Avoid adding empty strings
      end
    end

    if tag
      tag.split.each do |word|
        if word.starts_with?('-') && word.size > 1
          # Tags to exclude
          command << "-T" << word[1..] # Add -T flag and the word without the leading '-'
        elsif !word.starts_with? '-'
          # Tags to include
          command << "-t" << word # Add -t flag and the word
        end
      end
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
          LogEntry.from_json(line) # Use from_json to leverage JSON::Serializable and converters
        rescue ex : JSON::ParseException
          Log.warn { "Failed to parse log line: #{line.inspect[..100]}: #{ex.message}" }
          next
        rescue ex : ArgumentError # Can be raised by MicrosecondsEpochConverter if to_i64 fails
          Log.warn { "Failed to convert data in log line (e.g., timestamp): #{line.inspect[..100]}: #{ex.message}" }
          next
        end
      end
      # Sort the entries if sort_by is provided and log_entries is not nil
      if sort_by && log_entries
        is_ascending = sort_order.nil? || sort_order.downcase == "asc"
        Log.debug { "Sorting by '#{sort_by}', order: #{is_ascending ? "ASC" : "DESC"}" }

        log_entries.sort! do |a, b|
          # Primary comparison
          primary_cmp = case sort_by
                        when "timestamp"
                          a.timestamp <=> b.timestamp # Time objects are directly comparable
                        when "priority"
                          a.priority.to_i <=> b.priority.to_i # Uses getter, .to_i for numeric sort
                        when "message"
                          a.message.downcase <=> b.message.downcase # Uses getter
                        when "unit"                                 # Renamed from service
                          a.unit.downcase <=> b.unit.downcase
                        else
                          Log.warn { "Unknown sort_by key: #{sort_by}" }
                          0 # No change for unknown key
                        end

          # If primary keys are different, use that comparison.
          # Otherwise (if primary_cmp is 0), use timestamp as a secondary sort key,
          # unless we are already sorting by timestamp.
          final_cmp = if primary_cmp != 0 || sort_by == "timestamp"
                        primary_cmp
                      else
                        # Primary keys are equal, and not sorting by timestamp, so use timestamp as secondary.
                        a.timestamp <=> b.timestamp
                      end

          # Apply sort order
          is_ascending ? final_cmp : -final_cmp
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
