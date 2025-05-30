require "time"
require "./journalctl" # To access Journalctl::LogEntry
require "faker"        # Add faker for dynamic message generation

module FakeJournalData
  Log = ::Log.for(self)

  # A list of sample unit names for generating fake data.
  SAMPLE_UNIT_NAMES = [
    "sshd.service", "nginx.service", "systemd-journald.service",
    "cron.service", "myapp.service", "postgresql.service",
    "redis-server.service", "docker.service", nil, # nil to simulate entries without a unit
  ]

  # A list of sample container names.
  SAMPLE_CONTAINER_NAMES = [
    "webapp_prod_1", "api_gateway_alpha", "worker_beta_3", nil, # nil for non-containerized logs
  ]

  # Parses a time string similar to how journalctl might interpret it.
  # Handles just what we need.

  def self.parse_journalctl_time_string(time_str : String, relative_to : Time = Time.utc) : Time?
    # Handle relative offsets: -Xm, -Xd, -Xh, -XM, -Xy
    # m: minutes, d: days, h: hours, M: months, y: years
    if match = time_str.match(/^([+-]?)(\d+)(m|d|h|M|y)$/) # Specific units and cases
      sign_char = match[1]
      value = match[2].to_i
      unit = match[3]
      span = case unit
             when "m" then Time::Span.new(minutes: value)
             when "h" then Time::Span.new(hours: value)
             when "d" then Time::Span.new(days: value)
             when "M" then Time::Span.new(days: value*30)  # Uppercase M for months
             when "y" then Time::Span.new(days: value*365) # y for years
             else
               # This case should ideally not be reached if the regex is correct
               Log.warn { "Unmatched unit '#{unit}' in relative time offset despite regex match." }
               return nil
             end
      (sign_char == "-") ? (relative_to - span) : (relative_to + span)
    else
      nil # Unparseable
    end
  end

  # Mimics the behavior of Journalctl.run_journalctl_and_parse by returning
  # a fake list of log entries.
  #
  # Args:
  #   _journalctl_args: Unused in this fake implementation.
  #   _log_context_message: Unused in this fake implementation.
  #
  # Returns:
  #   An Array of Journalctl::LogEntry, filtered and sized according to parsed args.
  def self.fake_run_journalctl_and_parse(
    journalctl_args : Array(String),
    _log_context_message : String,
  ) : Array(Journalctl::LogEntry)
    entries = [] of Journalctl::LogEntry
    current_time = Time.local

    # Parse relevant arguments
    target_priority_max_numeric : Int32? = nil
    target_unit : String? = nil
    target_n_entries : Int32 = 5000
    should_reverse_order = false
    include_tags = [] of String         # For -t SYSLOG_IDENTIFIER
    exclude_tags = [] of String         # For -T SYSLOG_IDENTIFIER to exclude
    target_cursor_value : String? = nil # For --cursor
    since_time_str : String? = nil
    until_time_str : String? = nil
    grep_query : String? = nil          # For -g

    i = 0
    while i < journalctl_args.size
      arg = journalctl_args[i]
      case arg
      when "-p"
        val = journalctl_args[i + 1].to_i? # Assume value is present
        target_priority_max_numeric = val if val && val.in?(0..7)
        i += 1 # Consume the value
      when "-u", "--unit"
        target_unit = journalctl_args[i + 1] # Assume value is present
        i += 1 # Consume the value
      when "-n"
        val = journalctl_args[i + 1].to_i? # Assume value is present
        target_n_entries = val if val && val > 0
        i += 1 # Consume the value
      when "-t" # SYSLOG_IDENTIFIER to include
        include_tags << journalctl_args[i + 1] # Assume value is present
        i += 1 # Consume the value
      when "-T" # SYSLOG_IDENTIFIER to exclude
        exclude_tags << journalctl_args[i + 1] # Assume value is present
        i += 1 # Consume the value
      when "--cursor"
        target_cursor_value = journalctl_args[i + 1] # Assume value is present
        i += 1 # Consume the value
      when "-S", "--since"
        since_time_str = journalctl_args[i + 1] # Assume value is present
        i += 1 # Consume the value
      when "--until"
        until_time_str = journalctl_args[i + 1] # Assume value is present
        i += 1 # Consume the value
      when "-g" # Grep query
        grep_query = journalctl_args[i + 1] # Assume value is present
        i += 1 # Consume the value
      when "-r", "--reverse"
        should_reverse_order = true
      end
      i += 1
    end

    # Determine time window for log generation
    # Default end_time is current_time (now)
    end_time = until_time_str ? parse_journalctl_time_string(until_time_str, current_time) : current_time
    end_time ||= current_time # Ensure end_time is not nil

    # Default start_time is 2 hours before end_time
    default_start_time = end_time - 2.hours
    pp! default_start_time
    start_time = since_time_str ? parse_journalctl_time_string(since_time_str, current_time) : default_start_time
    pp! start_time, since_time_str, parse_journalctl_time_string(since_time_str.to_s, current_time)
    start_time ||= default_start_time # Ensure start_time is not nil
    pp! start_time

    # Ensure start_time is not after end_time
    if start_time > end_time
      Log.warn { "Since time '#{since_time_str}' is after until time '#{until_time_str}'. Using until_time as both start and end." }
      start_time = end_time
    end

    # If -n is explicitly passed (e.g. for context or details calls), target_n_entries will be small.
    # If it's the default 5000 from a general /logs query, we generate a random smaller amount.
    num_entries_to_generate = [target_n_entries.to_i, rand(50..250)].min

    max_attempts = num_entries_to_generate * 10 + 50 # Safety break for the generation loop
    attempts = 0

    while entries.size < num_entries_to_generate && attempts < max_attempts
      attempts += 1

      # Generate timestamp within the determined range
      start_unix_ms = start_time.to_unix_ms
      end_unix_ms = end_time.to_unix_ms
      # Ensure range is valid for rand
      random_unix_ms = (start_unix_ms <= end_unix_ms) ? rand(start_unix_ms..end_unix_ms) : start_unix_ms
      timestamp = Time.unix_ms(random_unix_ms)

      raw_priority_val = target_priority_max_numeric ? rand(0..target_priority_max_numeric.not_nil!).to_s : rand(0..7).to_s

      current_internal_unit_name = target_unit || SAMPLE_UNIT_NAMES.sample # Corrected: Use SAMPLE_UNIT_NAMES
      syslog_identifier = current_internal_unit_name.nil? ? "kernel" : current_internal_unit_name.gsub(/\.service$/, "")
      message_raw = Faker::Hacker.say_something_smart
      container_name = SAMPLE_CONTAINER_NAMES.sample

      # Filter by tags
      next if !include_tags.empty? && !include_tags.includes?(syslog_identifier) # Corrected: Filter on syslog_identifier
      next if !exclude_tags.empty? && exclude_tags.includes?(syslog_identifier)  # Corrected: Filter on syslog_identifier

      # Filter by grep_query (if provided)
      if q = grep_query
        next unless message_raw.downcase.includes?(q.downcase)
      end

      # Populate the data hash, simulating journalctl -o json output
      data = Hash(String, String).new
      data["__REALTIME_TIMESTAMP"] = (timestamp.to_unix_ms).to_s # Microseconds string
      data["__MONOTONIC_TIMESTAMP"] = rand(1_000_000..1_000_000_000).to_s
      data["__CURSOR"] = target_cursor_value || "fakecursor_#{entries.size}_#{timestamp.to_unix_ms}"
      data["_BOOT_ID"] = "fakebootid1234567890abcdef12345678"
      data["_TRANSPORT"] = ["journal", "stdout", "kernel"].sample
      data["_MACHINE_ID"] = "fakemachineid1234567890abcdef12"
      data["_HOSTNAME"] = "fakehost"
      data["PRIORITY"] = raw_priority_val
      data["SYSLOG_FACILITY"] = rand(0..23).to_s
      data["SYSLOG_IDENTIFIER"] = syslog_identifier # Use the derived and filtered identifier
      data["_PID"] = rand(100..65535).to_s
      data["_UID"] = rand(0..1000).to_s # Could be 0 for root, or other UIDs
      data["_GID"] = rand(0..1000).to_s
      data["_COMM"] = syslog_identifier # Often the same as syslog identifier
      data["_EXE"] = "/usr/bin/#{data["_COMM"]}"
      data["_CMDLINE"] = "#{data["_EXE"]} --fake-option"
      data["MESSAGE"] = message_raw

      if current_internal_unit_name
        data["_SYSTEMD_UNIT"] = current_internal_unit_name
        data["_SYSTEMD_CGROUP"] = "/system.slice/#{current_internal_unit_name}"
        data["_SYSTEMD_SLICE"] = "system.slice"
      end

      if container_name
        data["CONTAINER_NAME"] = container_name
        data["CONTAINER_ID_FULL"] = "fakecontainerid#{rand(100000..999999)}"
        data["CONTAINER_TAG"] = ""
      end

      entry = Journalctl::LogEntry.new(
        timestamp: timestamp,
        message_raw: message_raw,
        raw_priority_val: raw_priority_val,
        internal_unit_name: current_internal_unit_name,
        data: data
      )
      entries << entry
    end

    if attempts >= max_attempts && entries.size < num_entries_to_generate
      Log.warn { "Fake data generation: Reached max attempts (#{max_attempts}) but only generated #{entries.size}/#{num_entries_to_generate} entries due to restrictive filters (priority, unit, or tags)." }
    end

    # Sort entries based on whether a reverse flag was present
    if should_reverse_order
      entries.sort_by!(&.timestamp).reverse! # Newest first
    else
      entries.sort_by!(&.timestamp) # Chronological order
    end
    Log.debug { "Generated #{entries.size} fake log entries. Time window: #{start_time} to #{end_time}. Order: #{should_reverse_order ? "reverse chronological" : "chronological"}" }
    entries
  end
end
