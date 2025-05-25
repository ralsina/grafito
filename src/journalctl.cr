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

  # Queries the logs based on the provided criteria.
  #
  # Args:
  #   date: The date to filter logs by (YYYY-MM-DD).  Can be a Time object or a String.
  #   unit: The systemd unit to filter by (e.g., "nginx.service").
  #   tag:  The syslog identifier (tag) to filter by.
  #
  # Returns:
  #   A String containing the journalctl output, or nil if an error occurs.
  def self.query(
    date : Time | String | Nil = nil,
    unit : String | Nil = nil,
    tag : String | Nil = nil,
    live : Bool | Nil = nil,
    query : String | Nil = nil,
  ) : Array(LogEntry) | Nil
    Log.debug { "Executing Journalctl.query with arguments:" }
    Log.debug { "  Date: #{date.inspect}" }
    Log.debug { "  Unit: #{unit.inspect}" }
    Log.debug { "  Tag: #{tag.inspect}" }
    Log.debug { "  Live: #{live.inspect}" }
    Log.debug { "  Query: #{query.inspect}" }

    # Treat empty string parameters for unit and tag as nil
    unit = nil if unit.is_a?(String) && unit.strip.empty?
    tag = nil if tag.is_a?(String) && tag.strip.empty?
    query = nil if query.is_a?(String) && query.strip.empty?

    command = ["journalctl", "-o", "json", "-n", "100"]

    if date
      date_str = date.is_a?(Time) ? date.strftime("%Y-%m-%d") : date
      command << "--since" << date_str
    end

    if unit
      command << "-u" << unit
    end

    if tag
      command << "-t" << tag
    end

    if live == true
      # FIXME implement live view
      #   command << "-f" # Add follow flag for live view
    end

    if query
      command << "-g" << query
    end

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
          LogEntry.from_json(line)
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
end
