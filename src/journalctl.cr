require "json"
require "time"
require "log"

{% if flag?(:fake_journal) %}
  require "./fake_journal_data" # For fake data generation
{% end %}

# A wrapper for journalctl
class Journalctl
  # Setup a logger for this class
  Log = ::Log.for(self)

  # Custom JSON converter for __REALTIME_TIMESTAMP (microseconds string) to Time
  class MicrosecondsEpochConverter
    # Helper to convert from a string value, also handling nil or empty strings.
    def self.from_string(s_val : String?) : Time
      return Time.unix(0) if s_val.nil? || s_val.strip.empty?
      Time.unix_ms(s_val.to_i64 // 1000)
    rescue ex : ArgumentError
      Journalctl::Log.warn(exception: ex) { "Failed to parse timestamp string '#{s_val}' for Time conversion, defaulting to epoch." }
      Time.unix(0)
    end

    # Converts from JSON, typically called by JSON::Serializable.
    # Uses read_string_or_null to correctly handle JSON null values.
    def self.from_json(parser : JSON::PullParser) : Time
      s = parser.read_string_or_null
      from_string(s) # Delegate to the string version
    end

    def self.to_json(value : Time, builder : JSON::Builder)
      builder.string((value.to_unix_ms).to_s)
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

    @[JSON::Field(key: "_HOSTNAME", nilable: true)] # Allow nil from JSON
    property hostname : String?                     # Raw hostname from JSON, might be nil

    # Will hold all raw data from journalctl as string key-value pairs
    property data : Hash(String, String)

    # Constructor used by JSON::Serializable.
    # It's called with named arguments matching property names, after converters are applied.
    def initialize(
      @timestamp : Time,
      @message_raw : String?,              # Changed to String? to match property type
      @raw_priority_val : String?,         # Changed to String? to match property type
      @internal_unit_name : String? = nil, # Default to nil if _SYSTEMD_UNIT is missing
      @hostname : String? = nil,           # Default to nil if there is no _HOSTNAME
      @data : Hash(String, String) = {} of String => String,
    )
      # Properties are assigned directly by JSON::Serializable
      # Stripping and defaulting are handled by getters below.
    end

    # Custom from_json class method to take control of parsing.
    # This allows us to populate the 'data' field with all key-value pairs
    # from the JSON, converting all values to strings.
    def self.from_json(string_or_io, root : String? = nil)
      # 1. Parse the entire JSON into Hash(String, JSON::Any)
      # This allows access to all fields dynamically.
      json_as_any_hash = Hash(String, JSON::Any).from_json(string_or_io)

      # 2. Convert Hash(String, JSON::Any) to Hash(String, String) for the 'data' field
      # All values are converted to their string representation.
      all_data_as_string_hash = Hash(String, String).new
      json_as_any_hash.each do |key, value|
        all_data_as_string_hash[key] = value.to_s
      end

      # 3. Manually extract and convert specific fields for LogEntry properties
      #    using the json_as_any_hash.

      # Timestamp: Use the MicrosecondsEpochConverter.from_string helper
      ts_json_val = json_as_any_hash["__REALTIME_TIMESTAMP"]?
      timestamp = MicrosecondsEpochConverter.from_string(ts_json_val.try(&.as_s?))

      # Message: Get as String?
      message_raw = json_as_any_hash["MESSAGE"]?.try(&.as_s?)

      # Priority: Get as String?
      raw_priority_val = json_as_any_hash["PRIORITY"]?.try(&.as_s?)

      # Unit: Get as String?
      internal_unit_name = json_as_any_hash["_SYSTEMD_UNIT"]?.try(&.as_s?)

      # 4. Instantiate LogEntry with the processed values and the complete data hash
      LogEntry.new(
        timestamp: timestamp,
        message_raw: message_raw,
        raw_priority_val: raw_priority_val,
        internal_unit_name: internal_unit_name,
        data: all_data_as_string_hash
      )
    end

    # Getter for the cleaned message
    def message : String
      msg = @message_raw.to_s.strip
      container_name = @data["CONTAINER_NAME"]?
      if container_name && !container_name.strip.empty?
        return "[#{container_name.strip}]: #{msg}"
      end
      msg
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

    # Getter for the hostname
    def hostname : String
      (@data["_HOSTNAME"]? || "localhost").strip
    end

    def to_s
      # Use a standard timestamp format for to_s, and getters for other fields
      "#{timestamp.to_s("%Y-%m-%d %H:%M:%S.%L")} [#{hostname}] [#{unit}] [Prio: #{priority}] - #{message}"
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
    hostname : String | Nil,
  ) : Array(String)
    command = ["journalctl", "-m", "-o", "json", "-n", "5000", "-r"]

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

    if hostname && !hostname.strip.empty?
      # Add as a match filter for the _HOSTNAME field
      command << "_HOSTNAME=#{hostname.strip}"
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
    hostname : String | Nil = nil,
    sort_by : String | Nil = nil,
    sort_order : String | Nil = nil,
  ) : Array(LogEntry) | Nil
    Log.debug { "Executing Journalctl.query with arguments:" }
    Log.debug { "  Since: #{since.inspect}" }
    Log.debug { "  Unit: #{unit.inspect}" }
    Log.debug { "  Tag: #{tag.inspect}" }
    Log.debug { "  Query: #{query.inspect}" }
    Log.debug { "  Priority: #{priority.inspect}" }
    Log.debug { "  Hostname: #{hostname.inspect}" }
    Log.debug { "  SortBy: #{sort_by.inspect}" }
    Log.debug { "  SortOrder: #{sort_order.inspect}" }

    # Treat empty string parameters for unit and tag as nil
    unit = nil if unit.is_a?(String) && unit.strip.empty?
    tag = nil if tag.is_a?(String) && tag.strip.empty?
    query = nil if query.is_a?(String) && query.strip.empty?
    priority = nil if priority.is_a?(String) && priority.strip.empty?
    hostname_param = hostname.is_a?(String) && hostname.strip.empty? ? nil : hostname
    command = build_query_command(since, unit, tag, query, priority, hostname_param)
    Log.debug { "Generated journalctl command: #{command.inspect}" }

    # Use the helper to run the command and parse entries
    log_entries = run_journalctl_and_parse(command[1..], "Journalctl.query")

    # Sort the entries if sort_by is provided and log_entries is not empty
    if sort_by && !log_entries.empty?
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

    Log.debug { "Returning #{log_entries.size} log entries." }
    log_entries
  rescue ex
    Log.error(exception: ex) { "Error in Journalctl.query logic" }
    Log.debug { "Returning 0 log entries due to an exception." }
    nil
  end

  # Retrieves a list of all known systemd service units using systemctl.
  #
  # Returns:
  #   An Array(String) containing unique service unit names, sorted, or nil if an error occurs.
  def self.known_service_units : Array(String) | Nil
    {% if flag?(:fake_journal) %}
      Log.info { "Journalctl.known_service_units: Using FAKE service units." }
      fake_units = FakeJournalData::SAMPLE_UNIT_NAMES.compact.uniq.sort
      Log.debug { "Returning #{fake_units.size} fake service units." }
      return fake_units
    {% else %}
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
    {% end %}
  rescue ex
    Log.error(exception: ex) { "Error executing systemctl for known_service_units." }
    nil
  end

  # Retrieves a single log entry by its cursor.
  #
  # Args:
  #   cursor: The journalctl cursor string.
  #
  # Returns:
  #   A LogEntry object if found, or nil otherwise.
  def self.get_entry_by_cursor(cursor : String) : LogEntry?
    Log.debug { "Executing Journalctl.get_entry_by_cursor with cursor: #{cursor}" }
    command_args = ["-m", "-o", "json", "--cursor", cursor, "-n", "1"]

    entries = run_journalctl_and_parse(command_args, "Journalctl.get_entry_by_cursor for cursor '#{cursor}'")

    if entries.empty?
      Log.debug { "No entry found for cursor '#{cursor}' or command failed." }
      return nil
    end

    entries.first # Should be only one entry if found


  rescue ex # Catch unexpected errors in this method's logic
    Log.error(exception: ex) { "Unexpected error in Journalctl.get_entry_by_cursor for cursor: #{cursor}." }
    nil
  end

  # Helper method to run journalctl and parse JSON lines from its output.
  #
  # Args:
  #   journalctl_args: An array of arguments to pass to journalctl (excluding "journalctl" itself).
  #   log_context_message: A string to use as a prefix for log messages from this helper.
  #
  # Returns:
  #   An Array(LogEntry) parsed from the command output, or an empty array on failure.
  private def self.run_journalctl_and_parse(journalctl_args : Array(String), log_context_message : String) : Array(LogEntry)
    command = ["journalctl"] + journalctl_args
    {% if flag?(:fake_journal) %}
      Log.info { "#{log_context_message}: Using FAKE journal data." }
      # The fake function's arguments are prefixed with '_' indicating they might not be fully used.
      # It's designed to match the signature for easy swapping.
      FakeJournalData.fake_run_journalctl_and_parse(journalctl_args, log_context_message)
    {% else %}
      Log.debug { "#{log_context_message}: Executing command: #{command.inspect}" }

      stdout = IO::Memory.new
      process_result = Process.run(command[0], args: command[1..], output: stdout)

      if process_result.normal_exit?
        stdout.to_s.split("\n").compact_map do |line|
          next if line.strip.empty?
          begin
            LogEntry.from_json(line)
          rescue ex # Catches JSON::ParseException, ArgumentError, etc.
            Log.warn(exception: ex) { "#{log_context_message}: Failed to parse log line: #{line.inspect[..100]}" }
            nil
          end
        end
      else
        Log.warn { "#{log_context_message}: journalctl command failed with exit code: #{process_result.system_exit_status}. Stdout: #{stdout.to_s[0..100]}" }
        [] of LogEntry
      end
    {% end %}
  rescue ex
    Log.error(exception: ex) { "#{log_context_message}: Error executing journalctl. Command: #{command.inspect}" }
    [] of LogEntry
  end

  # Retrieves log entries surrounding a specific entry identified by a cursor.
  #
  # Args:
  #   cursor: The journalctl cursor string for the central entry.
  #   count: The number of entries to retrieve before and after the central entry.
  #
  # Returns:
  #   An Array(LogEntry) containing the 'before' entries, the target entry, and the 'after' entries,
  #   all in chronological order. Returns nil if the target cursor is not found or count is non-positive.
  def self.context(cursor : String, count : Int32) : Array(LogEntry)?
    if count <= 0
      Log.warn { "Context requested for cursor '#{cursor}' with non-positive count: #{count}. Returning nil." }
      return nil
    end

    target_entry = get_entry_by_cursor(cursor)
    unless target_entry
      Log.warn { "Context: Target entry for cursor '#{cursor}' not found. Returning nil." }
      return nil
    end

    # Fetch 'before' entries: `journalctl -o json --cursor <cursor> -n <count + 1> --reverse`
    # This outputs: [Target, B1, B2, ..., B_count] (Target is newest, B1 is just before Target, etc.)
    cmd_before_args = ["-m", "-o", "json", "--cursor", cursor, "-n", (count + 1).to_s, "--reverse"]
    parsed_before_list = run_journalctl_and_parse(cmd_before_args, "Context (before entries for cursor '#{cursor}')")

    before_entries = parsed_before_list.size > 1 ? parsed_before_list[1..].reverse : ([] of LogEntry)

    # Fetch 'after' entries: `journalctl -o json --after-cursor <cursor> -n <count>`
    # This outputs: [A1, A2, ..., A_count] (A1 is just after Target, in chronological order)
    cmd_after_args = ["-m", "-o", "json", "--after-cursor", cursor, "-n", count.to_s]
    after_entries = run_journalctl_and_parse(cmd_after_args, "Context (after entries for cursor '#{cursor}')")

    result = before_entries + [target_entry] + after_entries
    Log.info { "Context for cursor '#{cursor}' with count #{count}: Found #{before_entries.size} before, 1 target, #{after_entries.size} after. Total: #{result.size}" }
    result
  end
end
