# # Fake compose data
#
# Deterministic compose stacks for demo builds (`-Ddemo_mode`), the
# same idea as the fake journal and systemd data: a running stack, a
# stack with an unhealthy service and a stopped one, and one orphaned
# project whose compose files are gone, so every UI state is visible
# without Docker.
#
# The world is also *mutable*: simulated stack and service actions
# flip states (stopping the webapp stack really shows it as exited),
# and apps installed from the fake app store appear as real stacks.
# Overlays sit on top of the fixtures below, so bringing things back
# up restores the seeded scenario.

require "./compose_status"
require "./app_store"

module FakeComposeData
  # Plausible compose.yaml content for the web stack's YAML view.
  WEB_COMPOSE_YAML = <<-YAML
    services:
      web:
        image: nginx:1.27-alpine
        ports:
          - "8080:80"
        healthcheck:
          test: ["CMD", "wget", "-q", "-O", "-", "http://localhost/"]
          interval: 30s
      api:
        image: ghcr.io/example/webapp-api:latest
        environment:
          DATABASE_URL: postgres://db:5432/webapp
        depends_on:
          - db
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost:3000/healthz"]
          interval: 15s
          retries: 3
      db:
        image: postgres:16-alpine
        volumes:
          - db-data:/var/lib/postgresql/data
    volumes:
      db-data:
    YAML

  # Guarded mutable state: stacks brought down, individual services
  # stopped ("stack/service" keys), and stacks created by app store
  # installs (project name => catalog app).
  @@mutex = Mutex.new(protection: :checked)
  @@down_stacks = Set(String).new
  @@stopped_services = Set(String).new
  @@installed_stacks = {} of String => AppStore::AppInfo

  # The current world: fixture stacks with overlays applied, plus one
  # stack per simulated app store install.
  def self.stacks : Array(ComposeStatus::Stack)
    @@mutex.synchronize do
      fixture_stacks + installed_stacks
    end
  end

  # Simulates a stack-level compose action. Returns false for an
  # unknown stack. Demo builds only: no docker runs anywhere.
  def self.apply_stack_action(stack_name : String, action : String) : Bool
    @@mutex.synchronize do
      return false unless stack_known_locked?(stack_name)

      if action == "stop"
        @@down_stacks.add(stack_name)
      else # up, restart, update: everything running again
        @@down_stacks.delete(stack_name)
        @@stopped_services.reject!(&.starts_with?("#{stack_name}/"))
      end
      true
    end
  end

  # Simulates a service-level compose action. Returns false for an
  # unknown stack/service pair. Starting a service of a down stack
  # brings the stack back up, like `docker compose start` would want.
  def self.apply_service_action(stack_name : String, service_name : String, action : String) : Bool
    @@mutex.synchronize do
      return false unless service_known_locked?(stack_name, service_name)

      key = "#{stack_name}/#{service_name}"
      if action == "stop"
        @@stopped_services.add(key)
      else # start, restart
        @@stopped_services.delete(key)
        @@down_stacks.delete(stack_name)
      end
      true
    end
  end

  # Adds a stack for an app installed from the (fake) app store.
  def self.add_installed_stack(project_name : String, app_info : AppStore::AppInfo) : Nil
    @@mutex.synchronize do
      @@installed_stacks[project_name] = app_info
    end
  end

  # Removes a dynamically installed stack. Fixture scenery is
  # unaffected (uninstalling the fixture whoami keeps the webapp
  # stack; only the store badge goes away).
  def self.remove_installed_stack(project_name : String) : Bool
    @@mutex.synchronize do
      @@installed_stacks.delete(project_name) != nil
    end
  end

  # Restores the pristine demo compose world (spec hygiene, container
  # restarts do the same for the demo site).
  def self.reset_demo_state : Nil
    @@mutex.synchronize do
      @@down_stacks.clear
      @@stopped_services.clear
      @@installed_stacks.clear
    end
  end

  # The fake compose.yaml served by the YAML view for the web stack;
  # other stacks get a generic placeholder so the view is never empty.
  def self.compose_yaml(stack_name : String) : String
    if stack_name == "webapp"
      WEB_COMPOSE_YAML
    else
      "# #{stack_name}\nservices: {}\n"
    end
  end

  # Fake output for the job runner so the demo build can show the live
  # output view for any action.
  def self.fake_action_output(stack_name : String, action : String) : String
    case action
    when "update"
      "Pulling #{stack_name} ...\n Container #{stack_name}-web-1  Pulled\n Starting #{stack_name} ...\n Stack #{stack_name} updated"
    when "up"
      "Starting #{stack_name} ...\n Stack #{stack_name} started"
    when "install"
      "Rendering #{stack_name} files ...\n Pulling #{stack_name} ...\n Container #{stack_name}-1  Started\n App #{stack_name} installed"
    when "sync"
      "Downloading store tarball ...\n Unpacking ...\n Store synced"
    when "uninstall"
      "Stopping and removing containers ...\n Removing app files ...\n App #{stack_name} uninstalled"
    else
      "#{action.capitalize} #{stack_name} done"
    end
  end

  # ## Internals (call only while holding the mutex)

  private def self.stack_known_locked?(stack_name : String) : Bool
    {"monitoring", "webapp", "legacy"}.includes?(stack_name) ||
      @@installed_stacks.has_key?(stack_name)
  end

  private def self.service_known_locked?(stack_name : String, service_name : String) : Bool
    (fixture_stacks + installed_stacks).flat_map(&.services).any? do |service|
      service.stack == stack_name && service.service == service_name
    end
  end

  # The seeded scenery: a partially unhealthy webapp, a monitoring
  # stack that is still starting up, and an orphaned legacy project.
  private def self.fixture_stacks : Array(ComposeStatus::Stack)
    monitoring = [
      service("monitoring", "gotify", "monitoring-gotify-1", "running", "starting",
        "gotify/server:latest", "0.0.0.0:8081->80/tcp", "Up 20 seconds (health: starting)"),
      service("monitoring", "vector", "monitoring-vector-1", "exited", "",
        "timberio/vector:latest-alpine", "", "Exited (0) 5 minutes ago"),
    ]
    webapp = [
      service("webapp", "api", "webapp-api-1", "running", "unhealthy",
        "ghcr.io/example/webapp-api:latest", "", "Up 2 hours (unhealthy)"),
      service("webapp", "db", "webapp-db-1", "running", "healthy",
        "postgres:16-alpine", "127.0.0.1:5432->5432/tcp", "Up 3 days (healthy)"),
      service("webapp", "web", "webapp-web-1", "running", "healthy",
        "nginx:1.27-alpine", "0.0.0.0:8080->80/tcp", "Up 3 days (healthy)"),
    ]
    legacy = [
      service("legacy", "old-app", "legacy-old-app-1", "exited", "",
        "example/old-app:1.0", "", "Exited (0) 2 months ago"),
    ]
    [
      ComposeStatus::Stack.new(
        name: "monitoring",
        status: stack_status("monitoring", "running(1)"),
        config_files: ["/opt/stacks/monitoring/compose.yaml"],
        services: monitoring,
      ),
      ComposeStatus::Stack.new(
        name: "webapp",
        status: stack_status("webapp", "running(3)"),
        config_files: ["/opt/stacks/webapp/compose.yaml"],
        services: webapp,
      ),
      # An orphaned project: containers exist but the compose files are
      # gone, so no stack-level actions are possible.
      ComposeStatus::Stack.new(
        name: "legacy",
        status: stack_status("legacy", ""),
        config_files: [] of String,
        services: legacy,
      ),
    ]
  end

  # One stack per simulated app store install, running the app's
  # fixture image. Ports are arbitrary but stable, like a real
  # rendered compose file would be.
  private def self.installed_stacks : Array(ComposeStatus::Stack)
    @@installed_stacks.map do |project, app_info|
      app_port = app_info.port || 8080
      running = [
        service(project, app_info.id, "#{project}-#{app_info.id}-1", "running", "healthy",
          "#{app_info.id}:latest", "0.0.0.0:#{20_000 + app_port}->#{app_port}/tcp",
          "Up a few seconds (healthy)"),
      ]
      ComposeStatus::Stack.new(
        name: project,
        status: stack_status(project, "running(1)"),
        config_files: ["/opt/stacks/#{project}/compose.yaml"],
        services: running,
      )
    end
  end

  # A service record with the overlay applied: anything inside a down
  # stack, or individually stopped, reads as exited with no health.
  private def self.service(
    stack_name : String, service_name : String, container : String,
    default_state : String, default_health : String, image : String,
    ports : String, default_status : String,
  ) : ComposeStatus::Service
    stopped = @@down_stacks.includes?(stack_name) ||
              @@stopped_services.includes?("#{stack_name}/#{service_name}")
    if stopped
      ComposeStatus::Service.new(
        stack: stack_name,
        service: service_name,
        container: container,
        state: "exited",
        health: "",
        image: image,
        ports: ports,
        status_text: "Exited (0) a few seconds ago",
      )
    else
      ComposeStatus::Service.new(
        stack: stack_name,
        service: service_name,
        container: container,
        state: default_state,
        health: default_health,
        image: image,
        ports: ports,
        status_text: default_status,
      )
    end
  end

  # The `compose ls` status line, blanked to "exited" while the stack
  # is stopped.
  private def self.stack_status(stack_name : String, default_status : String) : String
    @@down_stacks.includes?(stack_name) ? "exited" : default_status
  end
end
