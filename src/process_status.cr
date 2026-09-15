# # Process status
#
# The process view is grafito's "htop on a page": a snapshot of every
# process on the machine with per-process CPU/memory usage, plus the
# per-core CPU meters that make htop feel like htop.
#
# Like [system_status.cr](system_status.cr.html) this reads `/proc`
# directly instead of adding dependencies. The one subtle part is
# per-process CPU percentage: `/proc/[pid]/stat` only exposes *cumulative*
# CPU time, so usage must be computed as a delta between two reads.
# The module keeps the last reading (process ticks and per-core totals)
# in class state guarded by a mutex, which works because the process
# view is polled by a single htmx timer.
#
# When compiled with `-Ddemo_mode` (the demo build) it returns
# plausible, time-varying fake processes instead.

require "json"
require "log"

module ProcessStatus
  Log = ::Log.for(self)

  # Kernel reports CPU time in clock ticks; Linux's userspace-visible
  # tick rate (USER_HZ) has been 100 forever.
  TICKS_PER_SEC = 100

  # One process as shown in the table. CPU percentage is "percent of one
  # core" like htop's default, so a multicore thread can exceed 100.
  record ProcessInfo,
    pid : Int32,
    user : String,
    cpu_pct : Float64,
    mem_pct : Float64,
    virt_kb : Int64,
    res_kb : Int64,
    state : String,
    cpu_time_sec : Float64,
    command : String do
    include JSON::Serializable

    def zombie? : Bool
      state == "Z"
    end
  end

  # Point-in-time view of the whole machine for the process view.
  record Snapshot,
    timestamp : Time,
    cpu_count : Int32,
    core_pcts : Array(Float64),
    load1 : Float64,
    mem_total_kb : Int64,
    mem_used_kb : Int64,
    tasks_total : Int32,
    tasks_running : Int32,
    processes : Array(ProcessInfo) do
    include JSON::Serializable
  end

  # Cumulative per-core CPU ticks, kept between reads to compute deltas.
  private record CoreTicks, total : Int64, idle : Int64

  # Cumulative per-process ticks, keyed by pid.
  private record ProcTicks, total : Int64, born_ms : Int64

  # The previous reading. Mutated under MUTEX only.
  private CORE_TICKS = Hash(String, CoreTicks).new
  private PROC_TICKS = Hash(Int32, ProcTicks).new
  private MUTEX      = Mutex.new

  # Monotonic reference for millisecond timestamps of readings.
  private BOOT_INSTANT = Time.instant

  # Returns the current process snapshot (fake data on the demo build).
  def self.snapshot : Snapshot
    {% if flag?(:demo_mode) %}
      fake_snapshot
    {% else %}
      real_snapshot
    {% end %}
  end

  # Sends a signal to a process. Returns false when the process does not
  # exist or the kernel/polkit refuses; the error message is surfaced
  # verbatim to the caller.
  def self.signal(pid : Int32, signal : Signal) : Bool
    Process.signal(signal, pid)
    true
  rescue ex
    Log.warn(exception: ex) { "signal #{signal} to pid #{pid} failed" }
    false
  end

  # Everything the detail panel shows about one process. Read straight
  # from /proc on demand (the table snapshot only carries the summary);
  # CPU percentage here is the process's lifetime average, which is the
  # honest number a single spot read can produce.
  record ProcessDetail,
    pid : Int32,
    user : String,
    uid : String,
    state : String,
    cpu_pct : Float64,
    mem_pct : Float64,
    virt_kb : Int64,
    res_kb : Int64,
    cpu_time_sec : Float64,
    threads : Int32,
    ppid : Int32,
    started : Time,
    command : String,
    unit : String do
    include JSON::Serializable

    def comm : String
      # Mirror the table: kernel threads are bracketed comm names.
      command.starts_with?("[") ? command[1...command.size - 1] : File.basename(command.split(" ").first? || command)
    end

    def zombie? : Bool
      state == "Z"
    end

    def stopped? : Bool
      state == "T"
    end

    def systemd_unit? : Bool
      !unit.empty?
    end
  end

  # Reads the detail record for one pid, or nil when the process does
  # not exist (or died between the panel opening and this read).
  def self.detail(pid : Int32) : ProcessDetail?
    {% if flag?(:demo_mode) %}
      fake_detail(pid)
    {% else %}
      real_detail(pid)
    {% end %}
  end

  # ## Real implementation

  private def self.real_snapshot : Snapshot
    core_ticks = read_core_ticks
    mem_total_kb = read_mem_total_kb

    MUTEX.synchronize do
      previous_cores = CORE_TICKS.dup
      previous_procs = PROC_TICKS.dup
      now_ms = (Time.instant - BOOT_INSTANT).total_milliseconds.to_i64

      # Per-core usage percentages from the tick deltas. First read
      # yields empty meters; the next poll (3s later) fills them in.
      core_pcts = [] of Float64
      core_ticks.each do |name, ticks|
        previous = previous_cores[name]?
        next unless previous
        delta_total = ticks.total - previous.total
        delta_idle = ticks.idle - previous.idle
        next unless delta_total > 0
        core_pcts << ((delta_total - delta_idle).to_f / delta_total * 100).clamp(0.0, 100.0)
      end
      core_pcts.sort!

      # Rebuild the tick caches: entries for vanished pids disappear,
      # new pids start with their process-start time as reference.
      CORE_TICKS.clear
      core_ticks.each { |name, ticks| CORE_TICKS[name] = ticks }
      PROC_TICKS.clear

      uptime_sec = read_uptime_sec
      processes = read_processes(previous_procs, now_ms, mem_total_kb, uptime_sec)
      processes.sort_by! { |info| -info.cpu_pct }

      running = processes.count(&.state.==("R"))
      used_kb = mem_total_kb - read_mem_available_kb
      Snapshot.new(
        timestamp: Time.local,
        cpu_count: core_pcts.size > 0 ? core_pcts.size : cpu_count,
        core_pcts: core_pcts,
        load1: read_load1,
        mem_total_kb: mem_total_kb,
        mem_used_kb: used_kb,
        tasks_total: processes.size,
        tasks_running: running,
        processes: processes,
      )
    end
  rescue ex
    Log.warn(exception: ex) { "Failed to read process snapshot" }
    Snapshot.new(
      timestamp: Time.local,
      cpu_count: 1,
      core_pcts: [] of Float64,
      load1: 0.0,
      mem_total_kb: 0,
      mem_used_kb: 0,
      tasks_total: 0,
      tasks_running: 0,
      processes: [] of ProcessInfo,
    )
  end

  # Reads cumulative CPU ticks for "cpu" (named "all") and every "cpuN".
  private def self.read_core_ticks : Hash(String, CoreTicks)
    ticks = Hash(String, CoreTicks).new
    File.each_line("/proc/stat") do |line|
      fields = line.split
      # Only the per-core lines (cpu0, cpu1, ...): the aggregate "cpu"
      # line is the sum of all of them and must not count as a core.
      next unless fields.size >= 5 && fields[0] =~ /^cpu\d+$/
      # Idle time includes iowait: the core is not doing work then.
      values = fields[1..].map(&.to_i64?)
      next if values.any?(Nil)
      total = values.compact.sum
      idle = (values[3]? || 0i64) + (values[4]? || 0i64)
      ticks[fields[0]] = CoreTicks.new(total, idle)
    end
    ticks
  end

  # Parses every /proc/[pid]/stat into a ProcessInfo. The second field
  # (comm) is parenthesized and may itself contain spaces and parens, so
  # everything after the last ')' is the fixed-field tail.
  private def self.read_processes(
    previous_procs : Hash(Int32, ProcTicks),
    now_ms : Int64,
    mem_total_kb : Int64,
    uptime_sec : Float64,
  ) : Array(ProcessInfo)
    infos = [] of ProcessInfo
    # Read once per snapshot, not once per process: this poll runs every
    # few seconds and /etc/passwd does not change between pids.
    users = user_names

    Dir.children("/proc").each do |entry|
      pid = entry.to_i32?
      next unless pid
      info = process_info(pid, users, previous_procs, now_ms, mem_total_kb, uptime_sec)
      infos << info if info
    rescue File::NotFoundError | File::AccessDeniedError
      # The process vanished between listing and reading; skip it.
    end
    infos
  end

  # Turns one pid's /proc/[pid]/stat into a ProcessInfo, or nil when the
  # entry is not a process directory with a well-formed stat file.
  private def self.process_info(
    pid : Int32,
    users : Hash(String, String),
    previous_procs : Hash(Int32, ProcTicks),
    now_ms : Int64,
    mem_total_kb : Int64,
    uptime_sec : Float64,
  ) : ProcessInfo?
    raw = File.read("/proc/#{pid}/stat")
    tail_start = raw.rindex(')')
    head_start = raw.index('(')
    return unless tail_start && head_start
    comm = raw[head_start + 1...tail_start]
    fields = raw[tail_start + 1..].split
    return unless fields.size >= 22
    process_info_from_fields(pid, comm, users, fields, previous_procs, now_ms, mem_total_kb, uptime_sec)
  end

  # Assembles the ProcessInfo from the fixed-field tail of a stat file.
  private def self.process_info_from_fields(
    pid : Int32,
    comm : String,
    users : Hash(String, String),
    fields : Array(String),
    previous_procs : Hash(Int32, ProcTicks),
    now_ms : Int64,
    mem_total_kb : Int64,
    uptime_sec : Float64,
  ) : ProcessInfo
    utime = fields[11].to_i64? || 0i64
    stime = fields[12].to_i64? || 0i64
    starttime = fields[19].to_i64? || 0i64
    vsize = fields[20].to_i64? || 0i64
    rss_pages = fields[21].to_i64? || 0i64

    total_ticks = utime + stime
    cpu_pct = cpu_percentage(pid, total_ticks, starttime, previous_procs, now_ms, uptime_sec)
    PROC_TICKS[pid] = ProcTicks.new(total_ticks, now_ms)

    res_kb = rss_pages * page_size_kb
    mem_pct = mem_total_kb > 0 ? res_kb.to_f / mem_total_kb * 100 : 0.0
    ProcessInfo.new(
      pid: pid,
      user: users[uid_of(pid)]? || "?",
      cpu_pct: cpu_pct.clamp(0.0, 100.0 * cpu_count),
      mem_pct: mem_pct.clamp(0.0, 100.0),
      virt_kb: vsize // 1024,
      res_kb: res_kb,
      state: fields[0],
      cpu_time_sec: total_ticks.to_f / TICKS_PER_SEC,
      command: command_of(pid, comm),
    )
  end

  # Percent of one core used by the process since the previous reading,
  # or its lifetime average on the first sighting so the very first
  # render is not all zeroes.
  private def self.cpu_percentage(
    pid : Int32,
    total_ticks : Int64,
    starttime : Int64,
    previous_procs : Hash(Int32, ProcTicks),
    now_ms : Int64,
    uptime_sec : Float64,
  ) : Float64
    previous = previous_procs[pid]?
    if previous
      delta_ms = now_ms - previous.born_ms
      if delta_ms > 0
        ((total_ticks - previous.total).to_f / TICKS_PER_SEC) / (delta_ms / 1000) * 100
      else
        0.0
      end
    else
      age_sec = uptime_sec - starttime.to_f / TICKS_PER_SEC
      age_sec > 0 ? (total_ticks.to_f / TICKS_PER_SEC) / age_sec * 100 : 0.0
    end
  end

  # Builds the detail record from the process's /proc files. The stat
  # parse reuses the same field layout as the table reader; the extras
  # (ppid, threads) come from the same tail.
  private def self.real_detail(pid : Int32) : ProcessDetail?
    raw = File.read("/proc/#{pid}/stat")
    tail_start = raw.rindex(')')
    head_start = raw.index('(')
    return unless tail_start && head_start
    comm = raw[head_start + 1...tail_start]
    fields = raw[tail_start + 1..].split
    return unless fields.size >= 22
    detail_from_fields(pid, comm, fields)
  rescue File::NotFoundError | File::AccessDeniedError
    nil
  end

  # Assembles the detail record from the fixed-field tail of a stat
  # file. The extras (ppid, threads) share the tail with the fields the
  # table reader uses.
  private def self.detail_from_fields(pid : Int32, comm : String, fields : Array(String)) : ProcessDetail
    uid = uid_of(pid)
    total_ticks = (fields[11].to_i64? || 0i64) + (fields[12].to_i64? || 0i64)
    starttime = fields[19].to_i64? || 0i64
    res_kb = (fields[21].to_i64? || 0i64) * page_size_kb
    mem_total_kb = read_mem_total_kb

    ProcessDetail.new(
      pid: pid,
      user: user_names[uid]? || "?",
      uid: uid,
      state: fields[0],
      # Lifetime average: a spot read has no previous delta to diff
      # against, and this is the same number the table's first render
      # shows, so the panel never contradicts the table.
      cpu_pct: lifetime_cpu_pct(total_ticks, starttime, read_uptime_sec),
      mem_pct: mem_pct_of(res_kb, mem_total_kb),
      virt_kb: (fields[20].to_i64? || 0i64) // 1024,
      res_kb: res_kb,
      cpu_time_sec: total_ticks.to_f / TICKS_PER_SEC,
      threads: fields[17].to_i32? || 1,
      ppid: fields[1].to_i32? || 0,
      started: process_start_time(starttime),
      command: command_of(pid, comm),
      unit: cgroup_unit(pid),
    )
  end

  private def self.mem_pct_of(res_kb : Int64, mem_total_kb : Int64) : Float64
    mem_total_kb > 0 ? (res_kb.to_f / mem_total_kb * 100).clamp(0.0, 100.0) : 0.0
  end

  # Lifetime-average CPU percentage (percent of one core).
  private def self.lifetime_cpu_pct(total_ticks : Int64, starttime : Int64, uptime_sec : Float64) : Float64
    age_sec = uptime_sec - starttime.to_f / TICKS_PER_SEC
    age_sec > 0 ? ((total_ticks.to_f / TICKS_PER_SEC) / age_sec * 100).clamp(0.0, nil) : 0.0
  end

  # Wall-clock time the process started: boot time plus the stat
  # starttime offset in ticks.
  private def self.process_start_time(starttime : Int64) : Time
    boot = Time.local - read_uptime_sec.seconds
    boot + (starttime / TICKS_PER_SEC).seconds
  rescue ex
    Log.warn(exception: ex) { "Failed to compute process start time" }
    Time.unix(0)
  end

  # The systemd unit owning the process, from its cgroup v2 path
  # (/sys/fs/cgroup is mounted and /proc/[pid]/cgroup reads "0::/...").
  # Falls back to the legacy controller layout for cgroup v1 hosts.
  private def self.cgroup_unit(pid : Int32) : String
    File.each_line("/proc/#{pid}/cgroup") do |line|
      # 0::/system.slice/nginx.service  or  10:cpu:/system.slice/...
      path = line.split(':').last?
      next unless path
      parts = path.split('/')
      parts.each do |segment|
        # Only real units, not slice scopes like system.slice or
        # user@1000.service sessions' intermediate slices.
        return segment if segment.ends_with?(".service") && !segment.includes?("@") &&
                          !segment.starts_with?("systemd-")
      end
    end
    ""
  rescue File::NotFoundError | File::AccessDeniedError
    ""
  end

  # cmdline is NUL-separated and empty for kernel threads; the comm name
  # is used for those. Only the first cmdline token is shown (the
  # executable), keeping rows one line tall like htop's default.
  private def self.command_of(pid : Int32, comm : String) : String
    raw = File.read("/proc/#{pid}/cmdline")
    first = raw.split('\0').first?
    command = first.to_s.strip
    command.empty? ? "[#{comm}]" : command
  rescue File::NotFoundError | File::AccessDeniedError
    "[#{comm}]"
  end

  # Real (not effective) uid from /proc/[pid]/status, so processes
  # running as root show as root even when they dropped privileges.
  private def self.uid_of(pid : Int32) : String
    File.each_line("/proc/#{pid}/status") do |line|
      if line.starts_with?("Uid:")
        return line.split[1]
      end
    end
    "?"
  rescue File::NotFoundError | File::AccessDeniedError
    "?"
  end

  # uid => name from /etc/passwd, read once per snapshot.
  private def self.user_names : Hash(String, String)
    users = Hash(String, String).new
    begin
      File.each_line("/etc/passwd") do |line|
        # name:password:uid:gid:gecos:home:shell — key on the uid.
        fields = line.split(':')
        users[fields[2]] = fields[0] if fields.size >= 3
      end
    rescue ex
      Log.warn(exception: ex) { "Failed to read /etc/passwd" }
    end
    users
  end

  private def self.read_load1 : Float64
    File.read("/proc/loadavg").split.first?.try(&.to_f?) || 0.0
  rescue ex
    Log.warn(exception: ex) { "Failed to read load average" }
    0.0
  end

  private def self.read_uptime_sec : Float64
    File.read("/proc/uptime").split.first?.try(&.to_f?) || 0.0
  rescue ex
    Log.warn(exception: ex) { "Failed to read uptime" }
    0.0
  end

  private def self.read_mem_total_kb : Int64
    meminfo_value("MemTotal")
  end

  private def self.read_mem_available_kb : Int64
    meminfo_value("MemAvailable")
  end

  private def self.meminfo_value(key : String) : Int64
    File.each_line("/proc/meminfo") do |line|
      if line.starts_with?("#{key}:")
        return line.split[1]?.try(&.to_i64?) || 0i64
      end
    end
    0i64
  rescue ex
    Log.warn(exception: ex) { "Failed to read #{key} from meminfo" }
    0i64
  end

  private def self.page_size_kb : Int64
    {% if flag?(:windows) %}
      4i64
    {% else %}
      (LibC.sysconf(LibC::SC_PAGESIZE) // 1024).to_i64
    {% end %}
  rescue
    4i64
  end

  private def self.cpu_count : Int32
    System.cpu_count
  rescue
    1
  end

  # ## Demo build
  #
  # FAKE_PROCESSES mirrors a small personal server: a handful of system
  # daemons, a web server and a database, with CPU usage that drifts so
  # the table and meters look alive across polls. Simulated signals
  # mutate an overlay: killed pids vanish, others can be paused (T)
  # and resumed.

  private FAKE_BOOT = Time.local - 20.days

  @@demo_mutex = Mutex.new(protection: :checked)
  @@demo_killed = Set(Int32).new
  @@demo_states = {} of Int32 => String

  # pid, user, state, cpu, mem%, virt KB, res KB, command, unit — the
  # pristine table, without overlays.
  private def self.fake_process_table
    angle = (Time.local - FAKE_BOOT).total_seconds / 7.0
    [
      {1, "root", "S", 0.5, 0.1, 180_000, 24_000, "/sbin/init splash", "init.scope"},
      {402, "root", "S", 0.2, 0.4, 320_000, 86_000, "/lib/systemd/systemd-journald", "systemd-journald.service"},
      {618, "root", "S", 0.1, 0.2, 96_000, 31_000, "/lib/systemd/systemd-udevd", "systemd-udevd.service"},
      {745, "message+", "S", 0.1, 0.3, 84_000, 42_000, "/usr/bin/dbus-daemon --system", "dbus.service"},
      {921, "root", "S", 1.8, 1.1, 1_240_000, 212_000, "/usr/bin/dockerd -H fd://", "docker.service"},
      {1103, "root", "S", 0.3, 0.9, 890_000, 168_000, "/usr/bin/containerd", "containerd.service"},
      {1240, "www-data", "S", 4.2 + 3.0 * Math.sin(angle), 2.3, 410_000, 452_000, "nginx: worker process", "nginx.service"},
      {1388, "postgres", "S", 2.6 + 2.5 * Math.cos(angle / 1.3), 6.8, 1_980_000, 1_310_000, "postgres: checkpointer", "postgresql.service"},
      {1502, "root", "S", 0.4, 0.6, 220_000, 118_000, "/usr/sbin/cron -f -P", "cron.service"},
      {1666, "ralsina", "S", 0.2, 0.4, 310_000, 79_000, "/usr/bin/fish", ""},
      {1801, "ralsina", "R", 12.5 + 8.0 * Math.sin(angle / 0.9).abs, 1.9, 2_400_000, 371_000, "grafito", "grafito.service"},
      {1950, "ralsina", "S", 3.1 + 2.0 * Math.cos(angle / 1.7), 4.4, 3_100_000, 856_000, "code --open-url", ""},
    ]
  end

  # The live table with the signal overlay applied: killed pids are
  # gone, paused ones read as T.
  private def self.fake_process_rows
    @@demo_mutex.synchronize do
      fake_process_table.reject { |row| @@demo_killed.includes?(row[0]) }.map do |row|
        if state_override = @@demo_states[row[0]]?
          {row[0], row[1], state_override, row[3], row[4], row[5], row[6], row[7], row[8]}
        else
          row
        end
      end
    end
  end

  # Simulates one process signal on the demo world. Returns false for
  # an unknown pid. Demo builds only: no real process is touched.
  def self.apply_signal(pid : Int32, action : String) : Bool
    @@demo_mutex.synchronize do
      known = !@@demo_killed.includes?(pid) &&
              fake_process_table.any? { |row| row[0] == pid }
      return false unless known

      case action
      when "term", "kill"
        @@demo_killed.add(pid)
        @@demo_states.delete(pid)
      when "stop"
        @@demo_states[pid] = "T"
      when "cont"
        @@demo_states.delete(pid)
      end
      true
    end
  end

  # Restores the pristine demo process table (spec hygiene, container
  # restarts do the same for the demo site).
  def self.reset_demo_state : Nil
    @@demo_mutex.synchronize do
      @@demo_killed.clear
      @@demo_states.clear
    end
  end

  # A detail record for one of the fake pids; unknown pids read as
  # "process vanished", like the real reader.
  private def self.fake_detail(pid : Int32) : ProcessDetail?
    row = fake_process_rows.find { |entry| entry[0] == pid }
    return unless row
    entry_pid, user, state, _cpu, mem_pct, virt, res, command, unit = row
    ProcessDetail.new(
      pid: entry_pid,
      user: user,
      uid: user == "root" ? "0" : "1000",
      state: state,
      cpu_pct: 1.2,
      mem_pct: mem_pct,
      virt_kb: virt,
      res_kb: res,
      cpu_time_sec: (entry_pid % 97) * 3.7,
      threads: (entry_pid % 7) + 1,
      ppid: entry_pid == 1 ? 0 : 1,
      started: FAKE_BOOT + (entry_pid % 50).minutes,
      command: command,
      unit: unit,
    )
  end

  private def self.fake_snapshot : Snapshot
    now_sec = (Time.local - FAKE_BOOT).total_seconds
    angle = now_sec / 7.0
    cores = 4

    processes = fake_process_rows.map do |entry|
      pid, user, state, cpu, mem_pct, virt, res, command, _unit = entry
      ProcessInfo.new(
        pid: pid,
        user: user,
        cpu_pct: cpu.clamp(0.0, 400.0),
        mem_pct: mem_pct,
        virt_kb: virt,
        res_kb: res,
        state: state,
        cpu_time_sec: (pid % 97) * 3.7,
        command: command,
      )
    end
    processes.sort_by! { |info| -info.cpu_pct }

    core_pcts = (0...cores).map do |core|
      (25.0 + 20.0 * Math.sin(angle + core * 1.4) + rand(-3.0..3.0)).clamp(1.0, 100.0)
    end
    mem_used_pct = (58.0 + 6.0 * Math.sin(angle / 3.0) + rand(-1.0..1.0)).clamp(5.0, 95.0)

    Snapshot.new(
      timestamp: Time.local,
      cpu_count: cores,
      core_pcts: core_pcts,
      load1: 1.6 + 0.7 * Math.sin(angle / 2.0) + rand(-0.2..0.4),
      mem_total_kb: 16_000_000,
      mem_used_kb: (16_000_000 * mem_used_pct / 100).to_i64,
      tasks_total: processes.size,
      tasks_running: processes.count(&.state.==("R")),
      processes: processes,
    )
  end
end
