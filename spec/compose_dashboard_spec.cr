require "./spec_helper"
require "file_utils"

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

# A disk-discovered stack docker does not know about: fully down.
private STOPPED_STACK = ComposeStatus::Stack.new(
  name: "kavita",
  status: "stopped",
  config_files: ["/data/stacks/kavita/compose.yml"],
  services: [] of ComposeStatus::Service,
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
    # Single-escaped: text() escapes, so the arrow shows as "->" on
    # screen (the old double-escaped &amp;gt; rendered literally).
    # The table shows the compacted mapping, not docker's raw string
    # with the 0.0.0.0: listen address.
    fragment.should contain("8080-&gt;80/tcp")
    fragment.should_not contain("0.0.0.0:8080")
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
    # And it opens the Detail panel (a swap into the hidden panel
    # alone would look like "spinner, then nothing"). Single quotes
    # arrive HTML-escaped.
    with_actions.should match(/hx-get="\/compose-yaml\?stack=webapp"[^>]*hx-on:htmx:after-request="if\(event\.detail\.successful\)\{showLogPanel\(&#39;detail&#39;\)\}/m)
  end

  it "shows only the stack actions that fit the stack's state" do
    running = ComposeDashboard.render_html([STACK], true)
    running.should contain(%(title="Stop stack"))
    running.should contain(%(title="Restart stack"))
    running.should contain(%(title="Pull images and up -d"))
    running.should_not contain(%(title="Start stack (up -d)"))

    stopped = ComposeDashboard.render_html([STOPPED_STACK], true)
    stopped.should contain(%(title="Start stack (up -d)"))
    stopped.should_not contain(%(title="Stop stack"))
    stopped.should_not contain(%(title="Restart stack"))
    stopped.should_not contain(%(title="Pull images and up -d"))
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
    fragment.should contain("setContainerFilterAndTrigger")
    fragment.should contain("/compose-service/webapp/web/stop")
  end

  it "renders port mappings as chips in the detail fragment" do
    fragment = ComposeDashboard.service_details_fragment(SERVICES[0], true)
    fragment.should contain("port-chip")
    fragment.should contain("port-host")
    fragment.should contain("port-arrow")
    fragment.should contain("port-container")
    fragment.should contain("port-proto")
  end

  describe "unified_diff" do
    it "returns nothing for identical content" do
      ComposeDashboard.unified_diff("a\nb\n", "a\nb\n").should be_empty
    end

    it "produces a unified hunk with context for a small change" do
      diff = ComposeDashboard.unified_diff("a\nb\nc\nd\ne\n", "a\nb\nC\nd\ne\n")
      # Context 3 over a 5-line file: one hunk covering everything.
      diff.should contain("@@ -1,5 +1,5 @@")
      diff.should_not contain("\n-b\n")
      diff.should contain("-c")
      diff.should contain("+C")
      diff.should contain(" d")
    end

    it "emits separate hunks for distant changes" do
      lines_old = (1..20).map(&.to_s)
      content_old = lines_old.join("\n") + "\n"
      content_new = lines_old.map { |l| l == "2" ? "TWO" : (l == "17" ? "SEVENTEEN" : l) }.join("\n") + "\n"
      diff = ComposeDashboard.unified_diff(content_old, content_new)
      diff.scan(/^@@/m).size.should eq(2)
      diff.should contain("-2")
      diff.should contain("+TWO")
      diff.should contain("-17")
      diff.should contain("+SEVENTEEN")
    end
  end

  describe "stack file editors" do
    it "resolves the .env path from the compose file's directory and requires it to exist" do
      dir = File.join(Dir.tempdir, "grafito-editor-spec-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(dir)
      compose_path = File.join(dir, "docker-compose.yml")
      File.write(compose_path, "services: {}\n")

      stack = ComposeStatus::Stack.new(
        name: "editor", status: "running(1)",
        config_files: [compose_path],
        services: [] of ComposeStatus::Service,
      )
      # No .env yet: nil.
      ComposeDashboard.stack_file_path(stack, ComposeDashboard::StackFile::Env).should be_nil
      # The compose file always resolves.
      ComposeDashboard.stack_file_path(stack, ComposeDashboard::StackFile::ComposeYaml).should eq(compose_path)

      File.write(File.join(dir, ".env"), "KEY=value\n")
      ComposeDashboard.stack_file_path(stack, ComposeDashboard::StackFile::Env).should eq(File.join(dir, ".env"))
      FileUtils.rm_rf(dir)
    end

    it "applies a draft atomically, keeping a rolling backup and returning the diff" do
      dir = File.join(Dir.tempdir, "grafito-editor-spec-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(dir)
      path = File.join(dir, ".env")
      File.write(path, "KEY=old\n")

      diff = ComposeDashboard.apply_stack_file(path, "KEY=new\nEXTRA=1\n")
      diff.should contain("-KEY=old")
      diff.should contain("+KEY=new")
      diff.should contain("+EXTRA=1")
      File.read(path).should eq("KEY=new\nEXTRA=1\n")
      File.read(path + ".grafito-bak").should eq("KEY=old\n")
      FileUtils.rm_rf(dir)
    end
  end

  it "renders the editor fragment with escaped content and review controls" do
    fragment = ComposeDashboard.file_editor_fragment(
      "webapp", ComposeDashboard::StackFile::ComposeYaml, "/opt/stacks/webapp/compose.yaml",
      "services:\n  web:\n    <image>: nginx\n",
    )
    fragment.should contain("compose-editor-textarea")
    fragment.should contain("Review changes")
    fragment.should contain("Cancel")
    # text() escapes, so the raw <image> never reaches the HTML.
    fragment.should contain("&lt;image&gt;")
    fragment.should_not contain("<image>")
  end

  it "renders the review fragment with a colored diff and an apply button" do
    fragment = ComposeDashboard.file_diff_fragment(
      "webapp", ComposeDashboard::StackFile::Env, "/opt/stacks/webapp/.env",
      "KEY=new\n", "@@ -1 +1 @@\n-KEY=old\n+KEY=new\n",
    )
    fragment.should contain("compose-file-diff")
    fragment.should contain("diff-del")
    fragment.should contain("diff-add")
    fragment.should contain("Apply")
    fragment.should contain("hx-confirm")
  end

  it "renders the applied fragment with an up -d shortcut when actions are on" do
    fragment = ComposeDashboard.file_applied_fragment(
      "webapp", ComposeDashboard::StackFile::ComposeYaml, "/opt/stacks/webapp/compose.yaml",
      "@@ -1 +1 @@\n", true,
    )
    fragment.should contain("compose.yaml written")
    fragment.should contain("compose-stack/webapp/up?from=panel")
  end

  it "renders a dash instead of chips when there are no ports" do
    fragment = ComposeDashboard.service_details_fragment(SERVICES[1], false)
    fragment.should contain("—")
    fragment.should_not contain("port-chip")
  end

  describe "parse_ports" do
    it "dedupes IPv4/IPv6 duplicates into one structured mapping" do
      raw = "0.0.0.0:8887-8888->8887-8888/tcp, [::]:8887-8888->8887-8888/tcp"
      mappings = ComposeDashboard.parse_ports(raw)
      mappings.size.should eq(1)
      mappings[0].host.should eq("8887-8888")
      mappings[0].container.should eq("8887-8888")
      mappings[0].protocol.should eq("tcp")
    end

    it "keeps distinct mappings" do
      mappings = ComposeDashboard.parse_ports("0.0.0.0:8080->80/tcp, 0.0.0.0:9090->90/udp")
      mappings.size.should eq(2)
      mappings[0].host.should eq("8080")
      mappings[1].host.should eq("9090")
      mappings[1].protocol.should eq("udp")
    end

    it "parses exposed-only ports without a host side" do
      mappings = ComposeDashboard.parse_ports("8888/tcp")
      mappings.size.should eq(1)
      mappings[0].host.should be_nil
      mappings[0].container.should eq("8888")
      mappings[0].protocol.should eq("tcp")
    end

    it "returns nothing for an empty ports string" do
      ComposeDashboard.parse_ports("").should be_empty
    end
  end

  it "renders the yaml fragment and the service-logs jump" do
    ComposeDashboard.yaml_fragment("webapp", "services: {}").should contain("services: {}")
    # The Service logs button opens the log view filtered by the
    # container's journald entries, not an inline tail.
    fragment = ComposeDashboard.service_details_fragment(SERVICES[0], false)
    fragment.should contain(%(onclick="return setContainerFilterAndTrigger(&#39;webapp-web-1&#39;)"))
    fragment.should_not contain("compose-logs")
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

private def new_journal_entry(timestamp : Time, message : String) : Journalctl::LogEntry
  Journalctl::LogEntry.new(
    timestamp: timestamp,
    message_raw: message,
    raw_priority_val: "5",
    internal_unit_name: "vector.service",
    data: {"SYSLOG_IDENTIFIER" => "freshrss"} of String => String,
  )
end

private def new_job : ComposeJobs::Job
  # Starts a fake job through the public API so the fragment specs
  # exercise the real object. In non-fake builds, `echo` is instant and
  # harmless.
  job_id = {% if flag?(:demo_mode) %}
             ComposeJobs.start("up spec", [] of Array(String))
           {% else %}
             ComposeJobs.start("up spec", [["true"]])
           {% end %}
  job = ComposeJobs.find(job_id)
  raise "compose job #{job_id} vanished immediately" unless job
  job
end
