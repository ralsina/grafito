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

    # Converts the timestamp to a formatted string using the configured timezone
    def formatted_timestamp_with_timezone(format = "%m-%d %H:%M:%S") : String
      time_in_timezone = convert_to_timezone(@timestamp)
      time_in_timezone.to_s(format)
    end

    # Converts a Time object to the configured timezone
    private def convert_to_timezone(time : Time) : Time
      timezone_config = Grafito.timezone.strip

      case timezone_config.downcase
      when "local"
        time.in(Time::Location.local)
      when "utc"
        time.in(Time::Location::UTC)
      else
        # Try to parse as timezone name (IANA) or GMT offset
        begin
          # Try IANA timezone name first
          Time.local(time.year, time.month, time.day, time.hour, time.minute, time.second, nanosecond: time.nanosecond, location: Time::Location.load(timezone_config))
        rescue ex
          # Try GMT offset format (e.g., GMT+5, GMT-3:30)
          if timezone_config.match(/^GMT([+-]\d+)(?::(\d+))?$/i)
            sign = $1[0]
            hours = $1[1..].to_i
            minutes = $2?.try(&.to_i) || 0

            offset_seconds = (hours * 3600 + minutes * 60)
            offset_seconds = -offset_seconds if sign == '-'

            time + offset_seconds.seconds
          else
            # Fallback to local time if timezone is invalid
            Grafito::Log.warn(exception: ex) { "Invalid timezone '#{timezone_config}', falling back to local time" }
            time.in(Time::Location.local)
          end
        end
      end
    end

    # Converts the numeric priority string to its textual representation.
    def formatted_priority : String
      case priority # Use the getter to ensure defaulting/cleaning
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
        Journalctl::Log.debug { "Unknown priority value: '#{priority}'" }
        priority
      end
    end
  end

  # Builds the journalctl command array based on the provided filters.
  # This is a private helper method.
  def self.build_query_command(
    since : String | Nil = nil,
    unit : String | Nil = nil,
    tag : String | Nil = nil,
    query : String | Nil = nil,
    priority : String | Nil = nil,
    hostname : String | Nil = nil,
    lines : Int32 = 5000,
  ) : Array(String)
    command = ["journalctl", "-m", "-o", "json", "-n", lines.to_s, "-r"]

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
      # Check if the query string matches the pattern for a direct field=value filter.
      # Examples: _SYSTEMD_UNIT=foo.service, MESSAGE=bar, MY_VAR=baz
      # Field names are typically uppercase and may start with an underscore.
      # The regex checks for an optional leading underscore, then one or more uppercase alphanumeric characters (or underscore) for the field name,
      # followed by an equals sign and any characters for the value.
      if query.matches?(/^_{0,1}[A-Z0-9_]+=.*$/)
        command << query # Pass verbatim as a journalctl match
      else
        command << "-g" << query # Use as a general text search pattern with -g
      end
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
  #
  # * since: A time offset, like -15m or nil for no filter
  # * unit: The systemd unit to filter by (e.g., "nginx.service").
  # * tag:  The syslog identifier (tag) to filter by.
  # * live: A boolean indicating if the logs should be streamed live (not implemented yet).
  # * query: A string to filter logs by a specific search term. If it's in the form of a
  #   `journalctl` field=value pair, it will be used as a direct match filter, otherwise
  #   will be passed with `-g`.
  # * priority: A string representing the log priority (0-7, e.g., "3" for errors).
  # * hostname: A string to filter logs by a specific hostname.
  # * sort_by: A string indicating the field to sort by (e.g., "timestamp", "priority", "message", "unit").
  # * sort_order: A string indicating the sort order, either "asc" for ascending or "desc" for descending.
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
    lines : Int32 = 5000,
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
    Log.debug { "  Lines: #{lines.inspect}" }
    Log.debug { "  SortBy: #{sort_by.inspect}" }
    Log.debug { "  SortOrder: #{sort_order.inspect}" }

    # Treat empty string parameters for unit and tag as nil
    unit = nil if unit.is_a?(String) && unit.strip.empty?
    tag = nil if tag.is_a?(String) && tag.strip.empty?
    query = nil if query.is_a?(String) && query.strip.empty?
    priority = nil if priority.is_a?(String) && priority.strip.empty?
    hostname_param = hostname.is_a?(String) && hostname.strip.empty? ? nil : hostname
    command = build_query_command(since, unit, tag, query, priority, hostname_param, lines: lines)
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
    {% if flag?(:no_systemctl) %}
      Log.warn { "Journalctl.known_service_units: Systemctl is disabled by configuration." }
      return nil
    {% elsif flag?(:fake_journal) %}
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

        # Filter by allowed units if set
        if Grafito.allowed_units
          allowed_set = Grafito.allowed_units.not_nil!.to_set
          filtered_units = known_units.select do |unit|
            # Check both the raw unit name and cleaned version
            unit_match = allowed_set.includes?(unit)
            unless unit_match
              # Try with .service suffix removed
              cleaned_unit = unit.gsub(/\.service$/, "")
              unit_match = allowed_set.includes?(cleaned_unit)

              # Check for substring matches as fallback
              unless unit_match
                unit_match = allowed_set.any? do |allowed|
                  unit.includes?(allowed) || cleaned_unit.includes?(allowed)
                end
              end
            end
            unit_match
          end
          Log.info { "Filtered service units from #{known_units.size} to #{filtered_units.size} based on restrictions" }
          filtered_units.sort
        else
          known_units.to_a.sort
        end
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
      return
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
        entries = stdout.to_s.split("\n").compact_map do |line|
          next if line.strip.empty?
          begin
            LogEntry.from_json(line)
          rescue ex # Catches JSON::ParseException, ArgumentError, etc.
            Log.warn(exception: ex) { "#{log_context_message}: Failed to parse log line: #{line.inspect[..100]}" }
            nil
          end
        end

        # Apply server-side unit filtering if allowed_units is set
        if Grafito.allowed_units
          allowed_set = Grafito.allowed_units.not_nil!.to_set
          Log.debug { "Unit filtering enabled. Allowed units: #{allowed_set.to_a}" }
          filtered_count = entries.size
          first_entry_unit = entries.first?.try { |e| e.internal_unit_name || e.unit } if entries.size > 0
          Log.debug { "First entry unit before filtering: #{first_entry_unit}" if first_entry_unit }

          entries = entries.select do |entry|
            # Check both the raw unit name and the cleaned version
            unit_match = false
            entry_unit = entry.internal_unit_name || entry.unit

            # Check internal_unit_name (with .service suffix)
            if entry.internal_unit_name
              unit_match ||= allowed_set.includes?(entry.internal_unit_name)
              Log.debug { "Unit filter: '#{entry.internal_unit_name}' exact match -> #{unit_match}" }
            end

            # Check cleaned unit name (without .service suffix)
            cleaned_unit = entry.unit
            unless unit_match
              unit_match ||= allowed_set.includes?(cleaned_unit)
              Log.debug { "Unit filter: '#{cleaned_unit}' cleaned match -> #{unit_match}" }
            end

            # Also check if the allowed units contain patterns that match (case-insensitive)
            unless unit_match
              unit_match = allowed_set.any? do |allowed|
                # Case-insensitive pattern matching
                entry.internal_unit_name.try { |u| u.downcase.includes?(allowed.downcase) } ||
                  cleaned_unit.downcase.includes?(allowed.downcase) ||
                  allowed.downcase.includes?(cleaned_unit.downcase)
              end
              Log.debug { "Unit filter: '#{entry_unit}' pattern match -> #{unit_match}" }
            end

            # Log if entry is filtered out
            unless unit_match
              Log.debug { "Filtered out entry from unit '#{entry_unit}' (allowed: #{allowed_set.to_a})" }
            end

            unit_match
          end
          filtered_count -= entries.size
          Log.info { "Filtered out #{filtered_count} log entries due to unit restrictions" } if filtered_count > 0
          Log.debug { "Remaining entries after filtering: #{entries.size}" }
        end

        entries
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
      return
    end

    target_entry = get_entry_by_cursor(cursor)
    unless target_entry
      Log.warn { "Context: Target entry for cursor '#{cursor}' not found. Returning nil." }
      return
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
