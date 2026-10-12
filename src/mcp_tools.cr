# # Grafito's MCP tools
#
# The tools exposed at `POST /mcp` (see [main.cr](main.cr.html) for the
# token gate). They wrap the same domain modules the web views use —
# [Journalctl](journalctl.cr.html), [ComposeStatus](compose_status.cr.html),
# [ProcessStatus](process_status.cr.html), [SystemStatus](system_status.cr.html)
# — so what an LLM client sees is exactly what the UI shows, and every
# mutation has the same shell equivalent (which the tool descriptions
# spell out, keeping with the teach-the-commands tradition).
#
# Mutation tools require `--enable-actions`, like their web button
# counterparts; without it they answer with an explicit error content.

require "json"
require "mcp"

require "./compose_status"
require "./journalctl"
require "./process_status"
require "./system_status"
require "./view_helpers"

module Grafito::Mcp
  Log = ::Log.for(self)

  # Extracts a string argument from MCP tool arguments (JSON::Any).
  def self.param_str(params : Hash(String, JSON::Any), key : String) : String?
    value = params[key]?
    return unless value
    str = value.as_s?
    return str if str && !str.empty?
    number = value.as_i?
    number.to_s if number
  end

  def self.param_int(params : Hash(String, JSON::Any), key : String) : Int32?
    params[key]?.try(&.as_i?)
  end

  # The MCP tools/call content shape: one text block with pretty JSON.
  def self.text_result(payload) : JSON::Any
    text = payload.is_a?(String) ? payload : payload.to_pretty_json
    JSON.parse(%({"content": [{"type": "text", "text": #{text.to_s.to_json}}], "isError": false}))
  end

  def self.error_result(message : String) : JSON::Any
    JSON.parse(%({"content": [{"type": "text", "text": #{message.to_s.to_json}}], "isError": true}))
  end

  # The shared gate for mutation tools, mirroring the web UI's
  # --enable-actions flag.
  def self.actions_error_if_gated : JSON::Any?
    return if Grafito.actions_available?
    error_result("Mutations are disabled: start grafito with --enable-actions (and authentication configured) to allow them.")
  end

  # ## Read tools

  class QueryLogsTool < MCP::AbstractTool
    self.tool_name = "query_logs"
    self.tool_description = %(Query the systemd journal (journald). Filters map 1:1 to journalctl: `since` is a time offset like "-1h", `unit` a systemd unit, `tag` a syslog identifier, `container` a docker container name (journald log driver), `query` a text search (or a verbatim FIELD=value match), `priority` 0-7. Equivalent shell: journalctl -f/-n with those flags.)
    self.tool_input_schema = %({"type":"object","properties":{ "since":{"type":"string","description":"Time offset, e.g. -1h, -15m"}, "unit":{"type":"string","description":"Systemd unit name, e.g. nginx.service"}, "tag":{"type":"string","description":"Syslog identifier"}, "query":{"type":"string","description":"Text search, or FIELD=value for an exact journald match"}, "priority":{"type":"integer","description":"0 (emerg) to 7 (debug): show this level and more severe"}, "hostname":{"type":"string"}, "container":{"type":"string","description":"Docker container name (CONTAINER_NAME)"}, "lines":{"type":"integer","description":"How many entries to return (default 200)"} }})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      entries = Journalctl.query(
        since: Mcp.param_str(params, "since"),
        unit: Mcp.param_str(params, "unit"),
        tag: Mcp.param_str(params, "tag"),
        query: Mcp.param_str(params, "query"),
        priority: Mcp.param_str(params, "priority"),
        hostname: Mcp.param_str(params, "hostname"),
        container: Mcp.param_str(params, "container"),
        lines: Mcp.param_int(params, "lines") || 200,
      )
      return Mcp.error_result("Failed to query the journal.") unless entries

      compact = entries.map do |entry|
        {
          "timestamp" => entry.timestamp.to_s("%F %T"),
          "priority"  => entry.priority,
          "unit"      => entry.unit,
          "tag"       => entry.tag,
          "message"   => entry.message,
        }
      end
      Mcp.text_result({"count" => compact.size, "entries" => compact})
    end
  end

  class JournalctlCommandTool < MCP::AbstractTool
    self.tool_name = "journalctl_command"
    self.tool_description = %(Returns the exact journalctl command line grafito would run for the given filters — same arguments as query_logs. Use it to learn how to query the journal from a shell.)
    self.tool_input_schema = %({"type":"object","properties":{ "since":{"type":"string"},"unit":{"type":"string"},"tag":{"type":"string"}, "query":{"type":"string"},"priority":{"type":"integer"}, "hostname":{"type":"string"},"container":{"type":"string"}, "lines":{"type":"integer"} }})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      command = Journalctl.build_query_command(
        since: Mcp.param_str(params, "since"),
        unit: Mcp.param_str(params, "unit"),
        tag: Mcp.param_str(params, "tag"),
        query: Mcp.param_str(params, "query"),
        priority: Mcp.param_str(params, "priority"),
        hostname: Mcp.param_str(params, "hostname"),
        container: Mcp.param_str(params, "container"),
        lines: Mcp.param_int(params, "lines") || 200,
      )
      Mcp.text_result({"command" => command.join(" ")})
    end
  end

  class ListStacksTool < MCP::AbstractTool
    self.tool_name = "list_stacks"
    self.tool_description = %(List the Docker Compose stacks grafito sees: name, lifecycle state (running / stopped / removed), and per-service image, state and published ports. Equivalent shell: docker compose ls --all plus docker ps.)
    self.tool_input_schema = %({"type":"object","properties":{}})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      stacks = ComposeStatus.stacks.map do |compose_stack|
        {
          "name"            => compose_stack.name,
          "state"           => compose_stack.running_count > 0 ? "running" : (compose_stack.services.empty? ? "removed" : "stopped"),
          "running_service" => compose_stack.running_count,
          "services"        => compose_stack.services.map do |compose_service|
            {"service" => compose_service.service, "image" => compose_service.image,
             "state" => compose_service.state, "ports" => compose_service.ports}
          end,
        }
      end
      Mcp.text_result({"count" => stacks.size, "stacks" => stacks})
    end
  end

  class InspectStackTool < MCP::AbstractTool
    self.tool_name = "inspect_stack"
    self.tool_description = %(Inspect one compose stack in depth: compose file paths, per-service details (image, state, health, ports, log driver), host mounts, and the exact docker compose commands behind each action. Equivalent shell: docker compose -f <file> ps and docker inspect.)
    self.tool_input_schema = %({"type":"object","properties":{ "stack":{"type":"string","description":"Stack name, as returned by list_stacks"} },"required":["stack"]})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      stack_name = Mcp.param_str(params, "stack")
      compose_stack = ComposeStatus.find_stack(stack_name.to_s)
      return Mcp.error_result("Stack '#{stack_name}' not found.") unless compose_stack

      mounts = ComposeStatus.container_mounts(compose_stack.services.map(&.container))
      Mcp.text_result({
        "name"         => compose_stack.name,
        "status"       => compose_stack.status,
        "config_files" => compose_stack.config_files,
        "services"     => compose_stack.services.map do |compose_service|
          {
            "service"    => compose_service.service,
            "container"  => compose_service.container,
            "image"      => compose_service.image,
            "state"      => compose_service.state,
            "health"     => compose_service.health,
            "ports"      => parse_ports(compose_service.ports).map { |mapping| "#{mapping.host}:#{mapping.container}/#{mapping.protocol}" },
            "log_driver" => compose_service.log_driver,
            "mounts"     => mounts[compose_service.container]? || [] of Tuple(String, String),
          }
        end,
        "action_commands" => {
          "start"   => ComposeStatus.action_commands(compose_stack, "up").map(&.join(" ")),
          "stop"    => ComposeStatus.action_commands(compose_stack, "stop").map(&.join(" ")),
          "restart" => ComposeStatus.action_commands(compose_stack, "restart").map(&.join(" ")),
          "update"  => ComposeStatus.action_commands(compose_stack, "update").map(&.join(" ")),
        },
      })
    end

    private def parse_ports(raw : String)
      ComposeDashboard.parse_ports(raw)
    end
  end

  class ListProcessesTool < MCP::AbstractTool
    self.tool_name = "list_processes"
    self.tool_description = %(Snapshot of the host's processes (from /proc): pid, user, state, CPU%, memory, command. Equivalent shell: ps aux / top / htop. `filter` matches user, pid or command text.)
    self.tool_input_schema = %({"type":"object","properties":{ "filter":{"type":"string","description":"Match user, pid or command text"}, "limit":{"type":"integer","description":"How many processes to return (default 50)"} }})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      snapshot = ProcessStatus.snapshot
      needle = Mcp.param_str(params, "filter").to_s.downcase
      matched = snapshot.processes.select do |process_info|
        needle.empty? ||
          process_info.user.downcase.includes?(needle) ||
          process_info.command.downcase.includes?(needle) ||
          process_info.pid.to_s.includes?(needle) ||
          process_info.compose_label.downcase.includes?(needle)
      end
      limit = Math.max(1, Math.min(500, Mcp.param_int(params, "limit") || 50))
      processes = matched.first(limit).map do |process_info|
        {
          "pid" => process_info.pid, "user" => process_info.user,
          "state" => process_info.state, "cpu_pct" => process_info.cpu_pct,
          "mem_pct" => process_info.mem_pct, "command" => process_info.command,
          "compose" => process_info.compose_label,
        }
      end
      Mcp.text_result({"total" => matched.size, "processes" => processes})
    end
  end

  class SystemStatusTool < MCP::AbstractTool
    self.tool_name = "system_status"
    self.tool_description = %(Host status: per-core CPU, load, memory, failed systemd units and the unit table. Equivalent shell: uptime, free -m, systemctl --failed.)
    self.tool_input_schema = %({"type":"object","properties":{}})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      snapshot = SystemStatus.snapshot
      failed = snapshot.units.select(&.failed?).map(&.unit)
      Mcp.text_result({
        "load1"           => snapshot.load1,
        "memory_used_pct" => snapshot.mem_used_pct,
        "disk_used_pct"   => snapshot.disk_used_pct,
        "uptime_sec"      => snapshot.uptime_sec,
        "units_total"     => snapshot.units_total,
        "failed_units"    => failed,
        "units"           => snapshot.units.map do |unit_state|
          {"unit" => unit_state.unit, "active" => unit_state.active_state,
           "sub" => unit_state.sub_state, "description" => unit_state.description}
        end,
      })
    end
  end

  # ## Mutation tools (require --enable-actions)

  class StackActionTool < MCP::AbstractTool
    self.tool_name = "stack_action"
    self.tool_description = %(Run a lifecycle action on a compose stack: start (up -d), stop, restart or update (pull then up -d). Requires --enable-actions. Equivalent shell: docker compose -f <file> <action>.)
    self.tool_input_schema = %({"type":"object","properties":{ "stack":{"type":"string"}, "action":{"type":"string","enum":["start","stop","restart","update"]} },"required":["stack","action"]})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      gated = Mcp.actions_error_if_gated
      return gated if gated
      stack_name = Mcp.param_str(params, "stack").to_s
      action = Mcp.param_str(params, "action").to_s
      compose_stack = ComposeStatus.find_stack(stack_name)
      return Mcp.error_result("Stack '#{stack_name}' not found.") unless compose_stack

      commands = ComposeStatus.action_commands(compose_stack, action)
      return Mcp.error_result("Unknown action '#{action}'.") if commands.empty?

      outputs = commands.map do |command|
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        result = Process.run(command[0], args: command[1..], output: stdout, error: stderr)
        {"command" => command.join(" "), "exit_code" => result.exit_code || 0,
         "output" => (stdout.to_s + stderr.to_s).strip[0..2000]}
      end
      ok = outputs.all? { |outcome| outcome["exit_code"] == 0 }
      Mcp.text_result({"ok" => ok, "ran" => outputs})
    end
  end

  class ServiceActionTool < MCP::AbstractTool
    self.tool_name = "service_action"
    self.tool_description = %(Start, stop or restart a single service of a compose stack. Requires --enable-actions. Equivalent shell: docker compose -f <file> <action> <service>.)
    self.tool_input_schema = %({"type":"object","properties":{ "stack":{"type":"string"}, "service":{"type":"string"}, "action":{"type":"string","enum":["start","stop","restart"]} },"required":["stack","service","action"]})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      gated = Mcp.actions_error_if_gated
      return gated if gated
      stack_name = Mcp.param_str(params, "stack").to_s
      service_name = Mcp.param_str(params, "service").to_s
      action = Mcp.param_str(params, "action").to_s
      compose_stack = ComposeStatus.find_stack(stack_name)
      return Mcp.error_result("Stack '#{stack_name}' not found.") unless compose_stack
      return Mcp.error_result("Service '#{service_name}' not found in stack '#{stack_name}'.") unless ComposeStatus.find_service(stack_name, service_name)
      return Mcp.error_result("Unknown action '#{action}'.") unless {"start", "stop", "restart"}.includes?(action)

      command = ["docker", "compose"] + compose_stack.config_files.flat_map { |file| ["-f", file] } + [action, service_name]
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      result = Process.run(command[0], args: command[1..], output: stdout, error: stderr)
      Mcp.text_result({
        "ok"        => result.success?,
        "command"   => command.join(" "),
        "exit_code" => result.exit_code || 0,
        "output"    => (stdout.to_s + stderr.to_s).strip[0..2000],
      })
    end
  end

  class UnitActionTool < MCP::AbstractTool
    self.tool_name = "unit_action"
    self.tool_description = %(Start, stop, restart, enable or disable a systemd unit — the same whitelist and guards as the dashboard's unit buttons. Requires --enable-actions. Equivalent shell: systemctl <action> <unit>.)
    self.tool_input_schema = %({"type":"object","properties":{ "unit":{"type":"string","description":"Unit name, e.g. nginx or nginx.service"}, "action":{"type":"string","enum":["start","stop","restart","enable","disable"]} },"required":["unit","action"]})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      gated = Mcp.actions_error_if_gated
      return gated if gated
      unit_name = Mcp.param_str(params, "unit").to_s
      action = Mcp.param_str(params, "action").to_s
      exit_code, output = SystemStatus.run_unit_action(unit_name, action)
      Mcp.text_result({"ok" => exit_code == 0, "exit_code" => exit_code, "output" => output})
    end
  end

  class ProcessActionTool < MCP::AbstractTool
    self.tool_name = "process_action"
    self.tool_description = %(Send a signal to a process: term (SIGTERM, polite stop), kill (SIGKILL), stop (freeze) or cont (resume). Requires --enable-actions. Equivalent shell: kill -<SIGNAL> <pid>.)
    self.tool_input_schema = %({"type":"object","properties":{ "pid":{"type":"integer"}, "action":{"type":"string","enum":["term","kill","stop","cont"]} },"required":["pid","action"]})

    def invoke(params : Hash(String, JSON::Any), env : HTTP::Server::Context? = nil)
      gated = Mcp.actions_error_if_gated
      return gated if gated
      pid = Mcp.param_int(params, "pid") || 0
      action = Mcp.param_str(params, "action").to_s
      return Mcp.error_result("Invalid pid.") if pid <= 1 || !File.exists?("/proc/#{pid}")
      signal = case action
               when "term" then Signal::TERM
               when "kill" then Signal::KILL
               when "stop" then Signal::STOP
               when "cont" then Signal::CONT
               else             return Mcp.error_result("Unknown action '#{action}'.")
               end
      ok = ProcessStatus.signal(pid, signal)
      ok ? Mcp.text_result({"ok" => true, "signal" => action, "pid" => pid}) : Mcp.error_result("Failed to signal pid #{pid}.")
    end
  end
end
