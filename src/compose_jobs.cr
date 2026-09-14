# # Compose jobs
#
# Stack-level compose actions (up, stop, restart, image update) can
# take a while and print progress the user wants to see, Dockge-style.
# Instead of blocking the HTTP request, an action starts a *job*: a
# background fiber runs the compose process, teeing stdout/stderr into
# an in-memory line buffer, and the browser polls a small fragment
# endpoint every second until the job finishes. No websockets, no SSE.
#
# Jobs live in a class-level hash and are pruned, so a long-running
# server doesn't accumulate them. On the demo build jobs don't run
# docker at all: they replay a few plausible lines so the UI flow can
# be exercised end to end.

require "log"
require "mutex"
require "process"
require "random"

{% if flag?(:fake_journal) %}
  require "./fake_compose_data"
{% end %}

module ComposeJobs
  Log = ::Log.for(self)

  # A read-only view of a job's progress, for the polling fragment.
  record Snapshot,
    lines : Array(String),
    running : Bool,
    exit_code : Int32?

  # One running (or finished) compose command and its output so far.
  class Job
    getter id : String
    getter title : String
    getter created_at : Time

    @mutex = Mutex.new(protection: :checked)
    @lines = [] of String
    @running = true
    @exit_code : Int32? = nil

    def initialize(@id : String, @title : String)
      @created_at = Time.utc
    end

    # Appends one output line. Called from the reader fibers; the mutex
    # keeps appends safe against the snapshot reads.
    def append(line : String) : Nil
      @mutex.synchronize do
        @lines << line
      end
    end

    # Marks the job finished with the process exit code.
    def finish(exit_code : Int32) : Nil
      @mutex.synchronize do
        @exit_code = exit_code
        @running = false
      end
    end

    # A consistent view of the lines so far plus the run state.
    def snapshot : Snapshot
      @mutex.synchronize do
        Snapshot.new(@lines.dup, @running, @exit_code)
      end
    end
  end

  # All known jobs, {id => Job}. Guarded: started from request fibers,
  # pruned from job fibers.
  JOBS       = {} of String => Job
  JOBS_MUTEX = Mutex.new(protection: :checked)

  # How many finished jobs to keep around, and how long, so a stray
  # poll after completion still finds its job.
  MAX_JOBS = 50
  JOB_TTL  = 1.hour

  # Starts a sequence of commands as one background job and returns its
  # id. The commands run in order without a shell; callers pass
  # argument arrays built from whitelisted stack/service names and
  # config file paths. (The image-update action is a sequence: pull,
  # then up -d.)
  def self.start(title : String, commands : Array(Array(String))) : String
    id = Random::Secure.hex(8)
    job = Job.new(id, title)
    JOBS_MUTEX.synchronize do
      prune_locked
      JOBS[id] = job
    end
    {% if flag?(:fake_journal) %}
      run_fake(job)
    {% else %}
      run_real(job, commands)
    {% end %}
    id
  end

  # Returns the job with the given id, or nil for unknown/expired ones.
  def self.find(id : String) : Job?
    JOBS_MUTEX.synchronize do
      JOBS[id]?
    end
  end

  # Drops finished jobs past the TTL and, if things ever run away,
  # the oldest ones above the cap.
  private def self.prune_locked : Nil
    cutoff = Time.utc - JOB_TTL
    JOBS.reject! do |_, job|
      snapshot = job.snapshot
      !snapshot.running && job.created_at < cutoff
    end
    while JOBS.size >= MAX_JOBS
      oldest = JOBS.min_by { |_, job| job.created_at }
      JOBS.delete(oldest[0])
    end
  end

  # Runs the commands in order, streaming stdout and stderr lines into
  # the job from reader fibers. A failing command stops the sequence.
  private def self.run_real(job : Job, commands : Array(Array(String))) : Nil
    Log.info { "Compose job #{job.id}: #{commands.map(&.join(" ")).join(" && ")}" }
    spawn do
      exit_code = 0
      commands.each do |command|
        exit_code = run_one(job, command)
        break unless exit_code == 0
      end
      job.finish(exit_code)
      Log.info { "Compose job #{job.id} finished with exit code #{exit_code}" }
    rescue ex
      job.append("Failed to run compose job: #{ex.message}")
      job.finish(1)
      Log.error(exception: ex) { "Compose job #{job.id} failed" }
    end
  end

  # Runs one command of a job, appending its output lines; returns the
  # process exit code.
  private def self.run_one(job : Job, command : Array(String)) : Int32
    process = Process.new(
      command[0],
      args: command[1..],
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe,
    )
    reader = ->(stream : IO) do
      stream.each_line do |line|
        job.append(line)
      end
    end
    # Wait for the readers first: they hit EOF when the child exits,
    # and Process#wait closes the pipes, so waiting on the process
    # first would pull the streams out from under the readers.
    done = Channel(Nil).new(2)
    spawn do
      reader.call(process.output)
      done.send(nil)
    end
    spawn do
      reader.call(process.error)
      done.send(nil)
    end
    2.times { done.receive }
    exit_status = process.wait
    exit_status.system_exit_status.to_i32
  end

  # Demo-build stand-in: no docker, just a few plausible lines with a
  # short delay so the polling UI shows a running state first.
  private def self.run_fake(job : Job) : Nil
    spawn do
      parts = job.title.split(" ", 2)
      action = parts[0]?
      stack_name = parts[1]? || "demo"
      lines = FakeComposeData.fake_action_output(stack_name, action.to_s)
      lines.each_line do |line|
        sleep 0.4.seconds
        job.append(line)
      end
      job.finish(0)
    end
  end
end
