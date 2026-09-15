# # System status
#
# The dashboard needs a snapshot of the machine's health: load, memory,
# disk usage, uptime and the state of systemd units. This module gathers
# that without adding dependencies: it reads a few files from `/proc` and
# shells out to `systemctl` and `df`, the same way [journalctl.cr](journalctl.cr.html)
# shells out to `journalctl`.
#
# When compiled with `-Ddemo_mode` (the demo build) it returns a small
# deterministic snapshot instead, so the dashboard works without systemd.

require "json"
require "log"
require "time"

{% if flag?(:demo_mode) %}
  require "./fake_journal_data"
{% end %}

module SystemStatus
  Log = ::Log.for(self)

  # The state of a single systemd unit as reported by
  # `systemctl list-units`.
  record UnitState,
    unit : String,
    load_state : String,
    active_state : String,
    sub_state : String,
    description : String do
    include JSON::Serializable

    def failed? : Bool
      active_state == "failed"
    end

    def running? : Bool
      active_state == "active"
    end
  end

  # A point-in-time view of the whole machine. This is what the dashboard
  # cards display and what the metrics sampler records over time.
  record Snapshot,
    timestamp : Time,
    load1 : Float64,
    mem_used_pct : Float64,
    disk_used_pct : Float64,
    uptime_sec : Int64,
    units_total : Int32,
    units_failed : Int32,
    units : Array(UnitState) do
    include JSON::Serializable
  end

  # Returns the current system snapshot. On the demo build this is fake
  # data; otherwise it reads /proc and queries systemctl.
  def self.snapshot : Snapshot
    {% if flag?(:demo_mode) %}
      fake_snapshot
    {% else %}
      real_snapshot
    {% end %}
  end

  # Returns just the unit states (used by the unit-action endpoint to
  # verify a unit exists before touching it).
  def self.unit_states : Array(UnitState)
    snapshot.units
  end

  # Raw `systemctl status` output for one unit, for the AI explanation
  # endpoint. Read-only, so it needs neither --enable-actions nor root.
  # Journal excerpts are stripped (-n 0) because the AI report already
  # carries a longer journal tail; colors and paging are disabled and
  # lines kept untruncated so the model sees clean, complete output.
  # Returns nil when systemctl fails (unit vanished, no systemd session).
  def self.unit_status_output(unit_name : String) : String?
    {% if flag?(:demo_mode) %}
      fake_unit_status_output(unit_name)
    {% else %}
      command = ["systemctl"] + Journalctl.user_flags +
                ["status", unit_name, "--no-pager", "-l", "--full", "-n", "0"]
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      process = Process.run(
        command[0],
        args: command[1..],
        output: stdout,
        error: stderr,
        env: {"SYSTEMD_COLORS" => "0", "LANG" => "C"},
      )
      output = stdout.to_s
      return output if process.success? && !output.empty?
      # systemctl exits non-zero for inactive/failed units while still
      # printing the full status block, which is exactly what we want.
      return output unless output.empty?
      Log.warn { "systemctl status #{unit_name} produced no output: #{stderr.to_s[0..200]}" }
      nil
    {% end %}
  rescue File::NotFoundError
    # Environments without systemd (CI containers): no status to show.
    nil
  rescue ex
    Log.warn(exception: ex) { "systemctl status #{unit_name} failed" }
    nil
  end

  # Per-unit file/systemd flags gathered in one batched call. Used to
  # decide which action buttons make sense for a unit.
  record UnitFileFlags,
    file_state : String,
    can_start : Bool

  # Returns the enablement and startability for every unit in one
  # batched `systemctl show` call: {unit name => UnitFileFlags}.
  # Units with no unit file state (e.g. generated ones) are omitted,
  # and the dashboard hides enable/disable for them.
  def self.unit_flags_map : Hash(String, UnitFileFlags)
    {% if flag?(:demo_mode) %}
      fake_unit_flags_map
    {% else %}
      unit_names = snapshot.units.map(&.unit)
      return {} of String => UnitFileFlags if unit_names.empty?

      command = ["systemctl"] + Journalctl.user_flags +
                ["show", "-p", "Id", "-p", "UnitFileState", "-p", "CanStart"] + unit_names
      stdout = IO::Memory.new
      Process.run(command[0], args: command[1..], output: stdout)

      states = Hash(String, UnitFileFlags).new
      current_id : String? = nil
      current_file_state = ""
      current_can_start = true
      flush = -> do
        if current_id
          states[current_id] = UnitFileFlags.new(current_file_state, current_can_start)
        end
      end
      stdout.to_s.each_line do |line|
        case
        when line.starts_with?("Id=")
          flush.call
          current_id = line[3..]
          current_file_state = ""
          current_can_start = true
        when line.starts_with?("UnitFileState=")
          current_file_state = line["UnitFileState=".size..].strip.downcase
        when line.starts_with?("CanStart=")
          current_can_start = line["CanStart=".size..].strip.downcase != "no"
        end
      end
      flush.call
      states
    {% end %}
  rescue ex
    Log.warn(exception: ex) { "Failed to read batched unit flags" }
    {} of String => UnitFileFlags
  end

  # ## Demo state
  #
  # The demo build's unit table and unit-file flags are mutable so
  # simulated actions have visible effects (stopping nginx really
  # shows it as dead until it is started again). Lazy-seeded and
  # guarded: dashboard polls and action endpoints run in fibers.

  @@demo_units_mutex = Mutex.new(protection: :checked)
  @@demo_units : Hash(String, UnitState)? = nil
  @@demo_unit_flags : Hash(String, UnitFileFlags)? = nil

  # Seeds the demo unit table: a healthy system with one failed unit,
  # so the dashboard shows every state.
  private def self.demo_units_seed : Hash(String, UnitState)
    {
      "cron.service"        => UnitState.new("cron.service", "loaded", "active", "exited", "Regular background program processing"),
      "docker.service"      => UnitState.new("docker.service", "loaded", "active", "running", "Docker Application Container Engine"),
      "fake-broken.service" => UnitState.new("fake-broken.service", "loaded", "failed", "failed", "Fake failing service"),
      "nginx.service"       => UnitState.new("nginx.service", "loaded", "active", "running", "A high performance web server"),
      "sshd.service"        => UnitState.new("sshd.service", "loaded", "active", "running", "OpenBSD Secure Shell server"),
    } of String => UnitState
  end

  private def self.demo_unit_flags_seed : Hash(String, UnitFileFlags)
    {
      "cron.service"        => UnitFileFlags.new("static", true),
      "fake-broken.service" => UnitFileFlags.new("disabled", true),
      "docker.service"      => UnitFileFlags.new("enabled", true),
      "nginx.service"       => UnitFileFlags.new("enabled", true),
      "sshd.service"        => UnitFileFlags.new("enabled", true),
    } of String => UnitFileFlags
  end

  private def self.demo_units : Hash(String, UnitState)
    @@demo_units_mutex.synchronize do
      @@demo_units ||= demo_units_seed
    end
  end

  private def self.demo_unit_flags : Hash(String, UnitFileFlags)
    @@demo_units_mutex.synchronize do
      @@demo_unit_flags ||= demo_unit_flags_seed
    end
  end

  # Simulates one systemctl action against the demo unit table and
  # returns the refreshed state, or nil for an unknown unit. Demo
  # builds only: no systemctl runs anywhere.
  def self.apply_unit_action(unit_name : String, action : String) : UnitState?
    @@demo_units_mutex.synchronize do
      units = @@demo_units ||= demo_units_seed
      unit_state = units[unit_name]?
      return unless unit_state

      case action
      when "stop"
        units[unit_name] = UnitState.new(unit_name, "loaded", "inactive", "dead", unit_state.description)
      when "start", "restart"
        # cron is a oneshot unit: it runs and exits.
        sub = unit_name == "cron.service" ? "exited" : "running"
        units[unit_name] = UnitState.new(unit_name, "loaded", "active", sub, unit_state.description)
      when "enable", "disable"
        flags = @@demo_unit_flags ||= demo_unit_flags_seed
        if unit_flags = flags[unit_name]?
          flags[unit_name] = UnitFileFlags.new(action == "enable" ? "enabled" : "disabled", unit_flags.can_start)
        end
      end
      units[unit_name]
    end
  end

  # Restores the pristine demo unit table (spec hygiene, container
  # restarts do the same for the demo site).
  def self.reset_demo_state : Nil
    @@demo_units_mutex.synchronize do
      @@demo_units = nil
      @@demo_unit_flags = nil
    end
  end

  # Unit states for demo builds: the live mutable table.
  private def self.fake_unit_flags_map : Hash(String, UnitFileFlags)
    demo_unit_flags.dup
  end

  # `systemctl status` stand-in for demo builds, derived from the
  # current simulated state so it stays coherent with actions: a
  # failed-looking block for failed units, a minimal one for the rest.
  private def self.fake_unit_status_output(unit_name : String) : String?
    unit_state = demo_units[unit_name]?
    return unless unit_state

    if unit_state.failed?
      <<-STATUS
        ● #{unit_name} - Fake failing service
             Loaded: loaded (/etc/systemd/system/#{unit_name}; enabled; preset: enabled)
             Active: failed (Result: exit-code) since Mon 2026-09-13 09:00:01 UTC; 4min 2s ago
            Process: 998 ExecStart=/usr/bin/fake-broken --run (code=exited, status=1/FAILURE)
              Main PID: 998 (code=exited, status=1/FAILURE)
        STATUS
    else
      "● #{unit_name}\n     Loaded: loaded\n     Active: #{unit_state.active_state} (#{unit_state.sub_state})\n   Main PID: 1234\n"
    end
  end

  # Point in the past the fake demo "booted" from; the fake uptime is
  # derived from it so it grows plausibly across restarts.
  FAKE_BOOT = Time.local - 30.days

  # Plausible, time-varying fake metrics: a slow memory wave, a load
  # average that bounces around, and a nearly-stable disk. Used by both
  # the live fake snapshot and the demo history pre-seeding, so the
  # chart has no visible seam between seeded and live samples.
  def self.fake_metrics_at(ts : Time) : NamedTuple(load1: Float64, mem_used_pct: Float64, disk_used_pct: Float64)
    angle = (ts - Time.local.at_beginning_of_day).total_minutes / 45.0
    {
      load1:         (1.1 + 0.6 * Math.sin(angle / 2.5 + 1.0) + rand(-0.3..0.6)).clamp(0.05, 9.0),
      mem_used_pct:  (55.0 + 9.0 * Math.sin(angle) + rand(-1.5..1.5)).clamp(5.0, 95.0),
      disk_used_pct: (47.5 + 0.4 * Math.sin(angle / 8.0) + rand(0.0..0.15)).clamp(0.0, 100.0),
    }
  end

  # A small snapshot for demo builds and fake-mode specs, with metrics
  # that drift over time so charts look alive. Unit states come from
  # the mutable demo table, so simulated actions are visible.
  private def self.fake_snapshot : Snapshot
    units = demo_units.values.sort_by!(&.unit)
    metrics = fake_metrics_at(Time.local)
    Snapshot.new(
      timestamp: Time.local,
      load1: metrics[:load1],
      mem_used_pct: metrics[:mem_used_pct],
      disk_used_pct: metrics[:disk_used_pct],
      uptime_sec: (Time.local - FAKE_BOOT).total_seconds.to_i64,
      units_total: units.size,
      units_failed: units.count(&.failed?),
      units: units,
    )
  end

  private def self.real_snapshot : Snapshot
    units = query_unit_states
    Snapshot.new(
      timestamp: Time.local,
      load1: read_load1,
      mem_used_pct: read_mem_used_pct,
      disk_used_pct: read_disk_used_pct,
      uptime_sec: read_uptime_sec,
      units_total: units.size,
      units_failed: units.count(&.failed?),
      units: units,
    )
  end

  # Reads the one-minute load average from /proc/loadavg.
  private def self.read_load1 : Float64
    first_field("/proc/loadavg").try(&.to_f?) || 0.0
  rescue ex
    Log.warn(exception: ex) { "Failed to read load average" }
    0.0
  end

  # Reads uptime seconds from /proc/uptime.
  private def self.read_uptime_sec : Int64
    seconds = first_field("/proc/uptime").try(&.to_f?)
    seconds ? seconds.to_i64 : 0i64
  rescue ex
    Log.warn(exception: ex) { "Failed to read uptime" }
    0i64
  end

  # Computes memory usage percentage from /proc/meminfo, using
  # MemAvailable (which accounts for caches) rather than MemFree.
  private def self.read_mem_used_pct : Float64
    values = Hash(String, Int64).new
    File.each_line("/proc/meminfo") do |line|
      parts = line.split
      key = parts[0]?.try(&.chomp(":"))
      value = parts[1]?.try(&.to_i64?)
      values[key] = value if key && value
    end
    total = values["MemTotal"]?
    available = values["MemAvailable"]?
    if total && total > 0 && available
      ((total - available).to_f / total * 100).clamp(0.0, 100.0)
    else
      0.0
    end
  rescue ex
    Log.warn(exception: ex) { "Failed to read memory info" }
    0.0
  end

  # Computes root filesystem usage via `df -k -P /`. POSIX output makes
  # the column layout stable: field 5 is the capacity percentage.
  private def self.read_disk_used_pct : Float64
    stdout = IO::Memory.new
    result = Process.run("df", args: ["-k", "-P", "/"], output: stdout)
    unless result.normal_exit?
      Log.warn { "df command failed with exit code #{result.system_exit_status}" }
      return 0.0
    end
    stdout.to_s.each_line do |line|
      fields = line.split
      next unless fields.size >= 5 && fields[5]? == "/"
      return fields[4].rchop("%").to_f?.try(&.clamp(0.0, 100.0)) || 0.0
    end
    Log.warn { "df output did not contain a '/' mount point" }
    0.0
  rescue ex
    Log.warn(exception: ex) { "Failed to read disk usage" }
    0.0
  end

  # Queries `systemctl list-units` and parses the plain output.
  # Each line is: UNIT LOAD ACTIVE SUB DESCRIPTION.
  #
  # Note: the --units whitelist does NOT apply here. It gates what may
  # be controlled (unit actions) and which logs are visible, but the
  # dashboard shows the state of every unit on the machine.
  private def self.query_unit_states : Array(UnitState)
    command = ["systemctl"] + Journalctl.user_flags +
              ["list-units", "--type=service", "--all", "--no-legend", "--plain"]
    stdout = IO::Memory.new
    result = Process.run(command[0], args: command[1..], output: stdout)
    unless result.normal_exit?
      Log.warn { "systemctl list-units failed with exit code #{result.system_exit_status}" }
      return [] of UnitState
    end

    units = [] of UnitState
    stdout.to_s.each_line do |line|
      next if line.strip.empty?
      # systemctl --plain pads columns with spaces; split on whitespace
      # and rejoin the description, which may itself contain spaces.
      fields = line.split
      unit_name = fields[0]?
      next unless unit_name && fields.size >= 4
      units << UnitState.new(
        unit: unit_name,
        load_state: fields[1],
        active_state: fields[2],
        sub_state: fields[3],
        description: fields.size >= 5 ? fields[4..].join(" ") : "",
      )
    end
    units.sort_by!(&.unit)
    units
  rescue ex
    Log.warn(exception: ex) { "Failed to query systemd units" }
    [] of UnitState
  end

  # Returns the first whitespace-separated field of a file, or nil.
  private def self.first_field(path : String) : String?
    File.read(path).split.first?
  end
end
