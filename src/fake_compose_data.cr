# # Fake compose data
#
# Deterministic compose stacks for demo builds (`-Dfake_journal`), the
# same idea as the fake journal and systemd data: a running stack, a
# stack with an unhealthy service and a stopped one, and one orphaned
# project whose compose files are gone, so every UI state is visible
# without Docker.

require "./compose_status"

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

  def self.stacks : Array(ComposeStatus::Stack)
    web_services = [
      ComposeStatus::Service.new(
        stack: "webapp",
        service: "api",
        container: "webapp-api-1",
        state: "running",
        health: "unhealthy",
        image: "ghcr.io/example/webapp-api:latest",
        ports: "",
        status_text: "Up 2 hours (unhealthy)",
      ),
      ComposeStatus::Service.new(
        stack: "webapp",
        service: "db",
        container: "webapp-db-1",
        state: "running",
        health: "healthy",
        image: "postgres:16-alpine",
        ports: "127.0.0.1:5432->5432/tcp",
        status_text: "Up 3 days (healthy)",
      ),
      ComposeStatus::Service.new(
        stack: "webapp",
        service: "web",
        container: "webapp-web-1",
        state: "running",
        health: "healthy",
        image: "nginx:1.27-alpine",
        ports: "0.0.0.0:8080->80/tcp",
        status_text: "Up 3 days (healthy)",
      ),
    ]
    monitoring_services = [
      ComposeStatus::Service.new(
        stack: "monitoring",
        service: "gotify",
        container: "monitoring-gotify-1",
        state: "running",
        health: "starting",
        image: "gotify/server:latest",
        ports: "0.0.0.0:8081->80/tcp",
        status_text: "Up 20 seconds (health: starting)",
      ),
      ComposeStatus::Service.new(
        stack: "monitoring",
        service: "vector",
        container: "monitoring-vector-1",
        state: "exited",
        health: "",
        image: "timberio/vector:latest-alpine",
        ports: "",
        status_text: "Exited (0) 5 minutes ago",
      ),
    ]
    [
      ComposeStatus::Stack.new(
        name: "monitoring",
        status: "running(1)",
        config_files: ["/opt/stacks/monitoring/compose.yaml"],
        services: monitoring_services,
      ),
      ComposeStatus::Stack.new(
        name: "webapp",
        status: "running(3)",
        config_files: ["/opt/stacks/webapp/compose.yaml"],
        services: web_services,
      ),
      # An orphaned project: containers exist but the compose files are
      # gone, so no stack-level actions are possible.
      ComposeStatus::Stack.new(
        name: "legacy",
        status: "",
        config_files: [] of String,
        services: [
          ComposeStatus::Service.new(
            stack: "legacy",
            service: "old-app",
            container: "legacy-old-app-1",
            state: "exited",
            health: "",
            image: "example/old-app:1.0",
            ports: "",
            status_text: "Exited (0) 2 months ago",
          ),
        ],
      ),
    ]
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
    else
      "#{action.capitalize} #{stack_name} done"
    end
  end
end
