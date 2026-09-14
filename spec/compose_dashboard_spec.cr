require "./spec_helper"

# ComposeDashboard fragment specs, using fixture data shaped like the
# ComposeStatus output.

private SERVICES = [
  ComposeStatus::Service.new(
    stack: "webapp", service: "web", container: "webapp-web-1",
    state: "running", health: "healthy", image: "nginx:1.27-alpine",
    ports: "0.0.0.0:8080->80/tcp", status_text: "Up 3 days (healthy)",
  ),
  ComposeStatus::Service.new(
    stack: "webapp", service: "api", container: "webapp-api-1",
    state: "running", health: "unhealthy", image: "api:1",
    ports: "", status_text: "Up 2 hours (unhealthy)",
  ),
  ComposeStatus::Service.new(
    stack: "webapp", service: "db", container: "webapp-db-1",
    state: "exited", health: "", image: "postgres:16-alpine",
    ports: "", status_text: "Exited (0) 5 minutes ago",
  ),
]

private STACK = ComposeStatus::Stack.new(
  name: "webapp",
  status: "running(2)",
  config_files: ["/opt/stacks/webapp/compose.yaml"],
  services: SERVICES,
)

private EMPTY_STACK = ComposeStatus::Stack.new(
  name: "legacy",
  status: "",
  config_files: [] of String,
  services: [] of ComposeStatus::Service,
)

describe ComposeDashboard do
  it "renders summary cards, stacks and services" do
    fragment = ComposeDashboard.render_html([STACK], false)
    fragment.should contain("webapp")
    fragment.should contain("nginx:1.27-alpine")
    fragment.should contain("0.0.0.0:8080-&amp;gt;80/tcp")
    fragment.should contain("tag-ok") # healthy pill
    fragment.should contain("compose-output-area-webapp")
  end

  it "renders an empty state without stacks" do
    fragment = ComposeDashboard.render_html([] of ComposeStatus::Stack, false)
    fragment.should contain("No Docker Compose stacks found")
  end

  it "only offers action buttons when actions are enabled" do
    with_actions = ComposeDashboard.render_html([STACK], true)
    without_actions = ComposeDashboard.render_html([STACK], false)
    with_actions.should contain("hx-confirm")
    without_actions.should_not contain("hx-confirm")
    # The YAML view is read-only, so it stays available without actions.
    without_actions.should contain("compose-yaml?stack=webapp")
  end

  it "hides stack actions for stacks without config files" do
    fragment = ComposeDashboard.render_html([EMPTY_STACK], true)
    fragment.should contain("legacy")
    fragment.should_not contain("/compose-stack/legacy/up")
  end

  it "renders the service detail fragment" do
    fragment = ComposeDashboard.service_details_fragment(SERVICES[0], true)
    fragment.should contain("webapp / web")
    fragment.should contain("webapp-web-1")
    fragment.should contain("compose-logs?stack=webapp&amp;service=web")
    fragment.should contain("/compose-service/webapp/web/stop")
  end

  it "renders the yaml and logs fragments" do
    ComposeDashboard.yaml_fragment("webapp", "services: {}").should contain("services: {}")
    logs_fragment = ComposeDashboard.logs_fragment("webapp", "web", "log line 1")
    logs_fragment.should contain("log line 1")
    logs_fragment.should contain("every 5s")
  end

  it "renders a placeholder for empty log tails" do
    ComposeDashboard.logs_fragment("webapp", "web", "").should contain("(no logs)")
  end

  describe "output_fragment" do
    it "polls itself while the job runs" do
      job = new_job
      fragment = ComposeDashboard.output_fragment(job, "compose-output-webapp")
      fragment.should contain("Running")
      fragment.should contain("data-job-running=\"true\"")
      fragment.should contain("hx-trigger=\"every 1s\"")
      fragment.should contain("compose-output/#{job.id}")
    end

    it "stops polling and reports the outcome when done" do
      job = new_job
      job.append("Pulled image")
      job.finish(0)
      fragment = ComposeDashboard.output_fragment(job, "compose-output-webapp")
      fragment.should contain("Done")
      fragment.should contain("data-job-running=\"false\"")
      fragment.should_not contain("hx-trigger")
      fragment.should contain("Pulled image")
    end

    it "reports failures with the exit code" do
      job = new_job
      job.finish(1)
      ComposeDashboard.output_fragment(job, "x").should contain("Failed (exit 1)")
    end
  end

  it "renders action errors for the panel" do
    fragment = ComposeDashboard.action_error_fragment("Stop", "webapp/web", "Access denied")
    fragment.should contain("Stop failed: webapp/web")
    fragment.should contain("Access denied")
  end
end

private def new_job : ComposeJobs::Job
  # Starts a fake job through the public API so the fragment specs
  # exercise the real object. In non-fake builds, `echo` is instant and
  # harmless.
  job_id = {% if flag?(:fake_journal) %}
             ComposeJobs.start("up spec", [] of Array(String))
           {% else %}
             ComposeJobs.start("up spec", [["true"]])
           {% end %}
  job = ComposeJobs.find(job_id)
  raise "compose job #{job_id} vanished immediately" unless job
  job
end
