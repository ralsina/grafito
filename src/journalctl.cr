require "json"
require "time"

# A wrapper for journalctl
class Journalctl
  # Represents a single log entry retrieved from journalctl.
  #
  # This class is used to parse and serialize log data.
  # It includes `JSON::Serializable` to allow easy conversion to and from JSON.
  #

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
  def self.query(date : Time | String | Nil = nil, unit : String | Nil = nil, tag : String | Nil = nil) : Array(LogEntry) | Nil
    command = ["journalctl", "-o", "json"]

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

    pp! command

    # Execute the command and capture the output.
    stdout = IO::Memory.new
    result = Process.run(
      command[0],
      args: command[1..],
      output: stdout,
    )
    if result == 0
      return stdout.to_s.split("\n").map do |line|
        LogEntry.from_json(line)
      end
    end
  rescue
    puts "Error executing journalctl: #{result}"
    nil
  end
end
