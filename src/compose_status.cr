# # Compose status
#
# The compose view needs a snapshot of the Docker Compose stacks running
# on this machine: which stacks exist, which services are up, their
# health, and enough information (config file paths, container names) to
# operate on them. This module gathers that by shelling out to the
# `docker` CLI, the same way [system_status.cr](system_status.cr.html)
# shells out to `systemctl`.
#
# Two calls per refresh, no docker API client:
#
# * `docker compose ls --all --format json` gives the stack list with
#   the compose file paths, which stack actions need (so commands don't
#   depend on the working directory).
# * `docker ps -a --format '{{json .}}'` gives every container with its
#   Compose labels (`com.docker.compose.project`,
#   `com.docker.compose.service`), state, health and ports.
#
# Containers whose project is missing from `compose ls` (config files
# moved or deleted) still show up, with no config files and therefore no
# stack-level actions.
#
# When compiled with `-Ddemo_mode` (the demo build) it returns a
# small deterministic snapshot instead, so the compose view works
# without Docker.

require "json"
require "log"

{% if flag?(:demo_mode) %}
  require "./fake_compose_data"
{% end %}

module ComposeStatus
  Log = ::Log.for(self)

  # One container of a compose stack, as shown in the service table.
  class Service
    include JSON::Serializable

    getter stack : String
    getter service : String
    getter container : String
    getter state : String
    getter health : String
    getter image : String
    getter ports : String
    getter status_text : String

    def initialize(
      @stack : String, @service : String, @container : String,
      @state : String, @health : String, @image : String,
      @ports : String, @status_text : String,
    )
    end

    def running? : Bool
      state == "running"
    end

    # Docker reports an empty health for containers without a
    # healthcheck; those are neither healthy nor unhealthy.
    def unhealthy? : Bool
      health == "unhealthy"
    end
  end

  # A compose stack: the `compose ls` metadata plus its containers.
  # `config_files` may be empty when the containers exist but the
  # compose files are gone; stack-level actions are impossible then.
  class Stack
    include JSON::Serializable

    getter name : String
    getter status : String
    getter config_files : Array(String)
    getter services : Array(Service)

    def initialize(
      @name : String, @status : String,
      @config_files : Array(String), @services : Array(Service),
    )
    end

    def running_count : Int32
      services.count(&.running?)
    end

    def unhealthy_count : Int32
      services.count(&.unhealthy?)
    end

    # True when the stack's compose files are known, so `up -d`-style
    # actions (which need -f) are possible.
    def actionable? : Bool
      !config_files.empty?
    end
  end

  # Which compose stack/service a container belongs to. The process
  # view keys on docker container IDs found in /proc/PID/cgroup to
  # attribute host processes to stacks and services.
  record ContainerRef, stack : String, service : String

  @@attribution_mutex = Mutex.new(protection: :checked)
  @@attribution : {Time, Hash(String, ContainerRef)}? = nil
  ATTRIBUTION_TTL = 60.seconds

  # Maps docker container IDs (full and 12-char prefix) to the compose
  # stack/service that owns them, from the running containers. Cached
  # for a minute: the process view polls every 5s and must not shell
  # out to `docker ps` on every tick.
  def self.container_attribution : Hash(String, ContainerRef)
    return {} of String => ContainerRef unless Grafito.compose_enabled?

    @@attribution_mutex.synchronize do
      cached = @@attribution
      return cached[1] if cached && (Time.utc - cached[0]) < ATTRIBUTION_TTL

      map = {} of String => ContainerRef
      ps_output = run_docker(["ps", "--format", "{{json .}}"])
      parse_containers(ps_output).each do |container|
        next unless container.state == "running"
        labels = container.labels_or_empty
        project = labels["com.docker.compose.project"]?
        service = labels["com.docker.compose.service"]?
        id = container.id
        next if project.nil? || service.nil? || id.nil? || id.empty?
        ref = ContainerRef.new(stack: project, service: service)
        map[id] = ref
        map[id[0, 12]] = ref if id.size >= 12
      end
      @@attribution = {Time.utc, map}
      map
    end
  end

  # Pure helper for specs: keys are the full container ID and its
  # 12-character prefix, values the stack/service pair.
  def self.attribution_from_containers(containers : Array(RawContainer)) : Hash(String, ContainerRef)
    map = {} of String => ContainerRef
    containers.each do |container|
      next unless container.state == "running"
      labels = container.labels_or_empty
      project = labels["com.docker.compose.project"]?
      service = labels["com.docker.compose.service"]?
      id = container.id
      next if project.nil? || service.nil? || id.nil? || id.empty?
      ref = ContainerRef.new(stack: project, service: service)
      map[id] = ref
      map[id[0, 12]] = ref if id.size >= 12
    end
    map
  end

  # The raw fields of one line of `docker ps --format '{{json .}}'` that
  # we care about. JSON::Serializable ignores unknown keys, so the rest
  # of docker's output is simply not mapped. Fields vary by CLI version:
  # Labels may be a JSON object, a comma-joined "k=v" string, or null;
  # Ports may be a string or null. So Labels is kept raw and normalized
  # by labels_or_empty, and Ports is nilable.
  class RawContainer
    include JSON::Serializable

    @[JSON::Field(key: "ID")]
    getter id : String?

    @[JSON::Field(key: "Names")]
    getter names : String

    @[JSON::Field(key: "Image")]
    getter image : String

    @[JSON::Field(key: "State")]
    getter state : String

    @[JSON::Field(key: "Status")]
    getter status : String

    @[JSON::Field(key: "Ports")]
    getter ports : String?

    @[JSON::Field(key: "Labels")]
    getter labels : JSON::Any?

    def ports_or_empty : String
      ports || ""
    end

    # Normalizes the Labels field to a plain hash, whatever shape the
    # docker CLI chose to emit.
    def labels_or_empty : Hash(String, String)
      result = Hash(String, String).new
      raw = labels
      return result if raw.nil?
      case raw.raw
      when Hash
        raw.as_h.each do |key, value|
          result[key] = value.as_s? || value.to_s
        end
      when String
        raw.as_s.split(',').each do |pair|
          key, _, value = pair.partition("=")
          result[key.strip] = value unless key.strip.empty?
        end
      end
      result
    end
  end

  # The raw fields of one entry of `docker compose ls --format json`,
  # mapped the same way as RawContainer.
  class RawStack
    include JSON::Serializable

    @[JSON::Field(key: "Name")]
    getter name : String

    @[JSON::Field(key: "Status")]
    getter status : String

    @[JSON::Field(key: "ConfigFiles")]
    getter config_files : String
  end

  # Returns the current snapshot of stacks and their services. On the
  # demo build this is fake data; otherwise it queries docker.
  def self.stacks : Array(Stack)
    {% if flag?(:demo_mode) %}
      FakeComposeData.stacks
    {% else %}
      real_stacks
    {% end %}
  end

  # Finds one stack by name, used by the detail/action endpoints to
  # validate that a stack name comes from the live snapshot.
  def self.find_stack(name : String) : Stack?
    stacks.find(&.name.==(name))
  end

  # Finds one service of one stack, used by the service detail/action
  # endpoints for the same whitelist purpose.
  def self.find_service(stack_name : String, service_name : String) : Service?
    find_stack(stack_name).try(&.services.find(&.service.==(service_name)))
  end

  private def self.real_stacks : Array(Stack)
    ls_output = run_docker(["compose", "ls", "--all", "--format", "json"])
    ps_output = run_docker(["ps", "-a", "--format", "{{json .}}"])

    stack_meta = parse_stack_meta(ls_output)
    containers = parse_containers(ps_output)

    # Group containers by their compose project label.
    by_project = Hash(String, Array(Service)).new
    containers.each do |container|
      labels = container.labels_or_empty
      project = labels["com.docker.compose.project"]?
      service = labels["com.docker.compose.service"]?
      next unless project && service
      by_project[project] ||= [] of Service
      by_project[project] << Service.new(
        stack: project,
        service: service,
        container: container.names,
        state: container.state,
        health: health_of(container.status, container.state),
        image: container.image,
        ports: container.ports_or_empty,
        status_text: container.status,
      )
    end

    # Stacks known to `compose ls` first (with config files), then any
    # container-only projects (config files unknown), sorted by name.
    result = [] of Stack
    stack_meta.each do |meta|
      result << Stack.new(
        name: meta["name"],
        status: meta["status"],
        config_files: meta["config_files"],
        services: (by_project[meta["name"]]? || [] of Service).sort_by(&.service),
      )
    end
    (by_project.keys - stack_meta.map(&.["name"])).sort.each do |orphan|
      result << Stack.new(
        name: orphan,
        status: "",
        config_files: [] of String,
        services: by_project[orphan].sort_by(&.service),
      )
    end
    result.sort_by(&.name)
  end

  # Parses `docker compose ls --format json` output into a metadata map
  # per stack: name, status and the list of compose file paths.
  def self.parse_stack_meta(output : String) : Array(NamedTuple(name: String, status: String, config_files: Array(String)))
    parsed = JSON.parse(output)
    entries = parsed.as_a? || [] of JSON::Any
    entries.compact_map do |entry|
      name = entry["Name"]?.try(&.as_s)
      next if !name || name.empty?
      config_files = entry["ConfigFiles"]?.try(&.as_s)
        .try { |files| files.split(',').map(&.strip).reject(&.empty?) } || [] of String
      {
        name:         name,
        status:       entry["Status"]?.try(&.as_s) || "",
        config_files: config_files,
      }
    end
  rescue ex
    Log.warn(exception: ex) { "Failed to parse docker compose ls output" }
    [] of NamedTuple(name: String, status: String, config_files: Array(String))
  end

  # Parses `docker ps --format '{{json .}}'` output: one JSON object
  # per line. Malformed lines are skipped, so one bad line doesn't hide
  # every stack.
  def self.parse_containers(output : String) : Array(RawContainer)
    containers = [] of RawContainer
    output.each_line do |line|
      next if line.strip.empty?
      begin
        containers << RawContainer.from_json(line)
      rescue JSON::ParseException
        Log.warn { "Skipping malformed docker ps line: #{line[0..80]}" }
      end
    end
    containers
  rescue ex
    Log.warn(exception: ex) { "Failed to parse docker ps output" }
    [] of RawContainer
  end

  # Extracts the healthcheck verdict from the `docker ps` Status string
  # (e.g. "Up 2 hours (healthy)"). Falls back to "starting" for running
  # containers with a healthcheck that hasn't reported yet, or "" when
  # the container has no healthcheck.
  private def self.health_of(status : String, state : String) : String
    match = status.match(/\((healthy|unhealthy|starting)\)/)
    return match[1] if match
    state == "running" && status.includes?("(health") ? "starting" : ""
  end

  # Runs docker and returns its stdout, or "" when docker is missing or
  # fails. A missing binary is the normal "no docker on this host" case
  # and stays quiet; real failures are logged. Public because the
  # compose-logs endpoint uses it for `docker compose logs`.
  def self.run_docker(args : Array(String)) : String
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    result = Process.run("docker", args: args, output: stdout, error: stderr)
    unless result.success?
      Log.warn { "docker #{args.join(" ")} failed with exit code #{result.system_exit_status}: #{stderr.to_s[0..200]}" }
      return ""
    end
    stdout.to_s
  rescue File::NotFoundError
    # Environments without docker: no stacks to show.
    ""
  rescue ex
    Log.warn(exception: ex) { "docker #{args.join(" ")} failed" }
    ""
  end
end
