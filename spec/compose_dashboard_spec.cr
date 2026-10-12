require "./spec_helper"
require "file_utils"

# ComposeDashboard fragment specs, using fixture data shaped like the
# ComposeStatus output.

private SERVICES = [
  ComposeStatus::Service.new(
    stack: "webapp", service: "web", container: "webapp-web-1",
    state: "running", health: "healthy", image: "nginx:1.27-alpine",
    ports: "0.0.0.0:8080->80/tcp", status_text: "Up 3 days (healthy)",
    log_driver: "journald",
  ),
  ComposeStatus::Service.new(
    stack: "webapp", service: "api", container: "webapp-api-1",
    state: "running", health: "unhealthy", image: "api:1",
    ports: "", status_text: "Up 2 hours (unhealthy)",
    log_driver: "json-file",
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
    # The card's compose.yaml button opens the editor for everyone
    # (read-only rendering without actions).
    without_actions.should contain("compose-file-edit?stack=webapp&amp;file=yaml")
    # And it opens the Detail panel (a swap into the hidden panel
    # alone would look like "spinner, then nothing"). Single quotes
    # arrive HTML-escaped.
    with_actions.should match(/hx-get="\/compose-file-edit\?stack=webapp&amp;file=yaml"[^>]*hx-on:htmx:after-request="if\(event\.detail\.successful\)\{showLogPanel\(&#39;detail&#39;\)\}/m)
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

  it "synthesizes an open link from published ports" do
    with_hostname = ComposeDashboard.render_html([STACK], true, hostname: "lab")
    # An open link is rendered either way; in demo builds the fake
    # store install owns webapp and provides its own URL.
    with_hostname.should contain("Open webapp (http://lab:")
    {% unless flag?(:demo_mode) %}
      with_hostname.should contain(%(href="http://lab:8080"))
      with_hostname.should contain("Open webapp (http://lab:8080)")
    {% end %}

    # No hostname (no Host header) → no synthesized link. (Store apps
    # keep their own URL regardless of hostname, so this only holds
    # when webapp is a plain stack — non-demo builds.)
    {% unless flag?(:demo_mode) %}
      without_hostname = ComposeDashboard.render_html([STACK], true)
      without_hostname.should_not contain("Open webapp (")
    {% end %}

    # A fully stopped stack has nothing reachable to open.
    stopped = ComposeDashboard.render_html([STOPPED_STACK], true, hostname: "lab")
    stopped.should_not contain("Open kavita (")
  end

  it "renders lifecycle cards that add up" do
    # webapp runs; the stopped fixture has containers but none running
    # is not representable here (its services list is empty), so it
    # counts as removed; legacy (no config, no services) also removed.
    fragment = ComposeDashboard.render_html([STACK, STOPPED_STACK, EMPTY_STACK], false)
    fragment.should contain(%(title="All known stacks"))
    fragment.should contain(%(<span class="stat-label">Running</span><span class="stat-value">1</span>))
    fragment.should contain(%(<span class="stat-label">Stopped</span><span class="stat-value">0</span>))
    fragment.should contain(%(<span class="stat-label">Removed</span><span class="stat-value">2</span>))
    fragment.should_not contain(%(<span class="stat-label">Services</span>))
  end

  it "explains a stack in prose and commands" do
    fragment = ComposeDashboard.compose_explain_fragment(
      STACK,
      {"webapp-web-1" => [{"/data/stacks/webapp/data", "/config"}]},
      hostname: "lab",
    )
    fragment.should contain(%(data-stack-name="webapp"))
    fragment.should contain(%(<span class="panel-nav-tab active">Explain</span>))
    fragment.should contain(%(<code>/opt/stacks/webapp/compose.yaml</code>))
    fragment.should contain("Compose file reference")
    fragment.should contain("nginx:1.27-alpine")
    fragment.should contain(%(<code>8080</code>))
    fragment.should contain(%(href="http://lab:8080"))
    fragment.should contain(%(<code>/data/stacks/webapp/data</code>))
    fragment.should contain("survives restarts and updates")
    fragment.should contain("docker compose -f /opt/stacks/webapp/compose.yaml ps")
    fragment.should contain("logs -f web")
  end

  it "degrades the explainer without mounts or a hostname" do
    fragment = ComposeDashboard.compose_explain_fragment(STACK, {} of String => Array(Tuple(String, String)))
    fragment.should contain("maps port")
    fragment.should_not contain("http://")
    fragment.should contain("docker compose -f /opt/stacks/webapp/compose.yaml restart")

    orphan = ComposeDashboard.render_html([EMPTY_STACK], false)
    orphan.should contain("legacy") # still listed; explainer degrades via no config sentence
  end

  it "renders N/A for services without a healthcheck" do
    fragment = ComposeDashboard.render_html([STACK], false)
    fragment.should contain(%(>N/A</span>))
    fragment.should_not contain(%(>—</span>))
  end

  it "tags stack cards and panel fragments with the stack name" do
    fragment = ComposeDashboard.render_html([STACK], true)
    fragment.should contain(%(data-stack-name="webapp"))
    panel = ComposeDashboard.service_details_fragment(SERVICES[0], false)
    panel.should contain(%(data-stack-name="webapp"))
  end

  it "renders a stack filter in the toolbar" do
    fragment = ComposeDashboard.render_html([STACK], false)
    fragment.should contain("compose-stack-filter")
    fragment.should contain("compose-filter-empty")
  end

  it "navigates between the panel views of a stack" do
    # The editor: active tab, plus tabs for Explain and the sibling file.
    editor = ComposeDashboard.file_editor_fragment(
      "webapp", ComposeDashboard::StackFile::ComposeYaml, "/opt/stacks/webapp/compose.yaml",
      "services: {}", editable: true)
    editor.should contain(%(data-stack-name="webapp"))
    editor.should contain(%(<span class="panel-nav-tab active">compose.yaml</span>))
    editor.should contain(%(hx-get="/compose-explain?stack=webapp" hx-target="#panel-detail-content" hx-swap="innerHTML" hx-indicator="#loading-spinner">Explain</button>))
    editor.should contain(%(hx-get="/compose-file-edit?stack=webapp&amp;file=env" hx-target="#panel-detail-content" hx-swap="innerHTML" hx-indicator="#loading-spinner">.env</button>))
    editor.should contain(%(data-editor="yaml"))
    editor.should contain("Review changes")

    # service details: Details tab active, hops to the compose editor.
    details = ComposeDashboard.service_details_fragment(SERVICES[0], false)
    details.should contain(%(<span class="panel-nav-tab active">Details</span>))
    # The tab carries the service so the editor can link back.
    details.should contain(%(hx-get="/compose-file-edit?stack=webapp&amp;file=yaml&amp;service=web" hx-target="#panel-detail-content" hx-swap="innerHTML" hx-indicator="#loading-spinner">compose.yaml</button>))
  end

  it "renders the editor read-only without actions" do
    editor = ComposeDashboard.file_editor_fragment(
      "webapp", ComposeDashboard::StackFile::ComposeYaml, "/opt/stacks/webapp/compose.yaml",
      "services: {}", editable: false)
    editor.should contain(%(readonly="readonly"))
    editor.should_not contain("Review changes")
    editor.should contain("Read-only")

    # With actions: editable.
    editable = ComposeDashboard.file_editor_fragment(
      "webapp", ComposeDashboard::StackFile::ComposeYaml, "/opt/stacks/webapp/compose.yaml",
      "services: {}", editable: true)
    editable.should contain("Review changes")
    editable.should_not contain("Read-only:")
  end

  it "offers a Details tab back when a file view came from a service" do
    editor = ComposeDashboard.file_editor_fragment(
      "webapp", ComposeDashboard::StackFile::ComposeYaml, "/opt/webapp/compose.yaml",
      "x", back_service: "web")
    editor.should contain(%(<span class="panel-nav-tab active">compose.yaml</span>))
    editor.should contain(%(hx-get="/compose-details?stack=webapp&amp;service=web" hx-target="#panel-detail-content" hx-swap="innerHTML" hx-indicator="#loading-spinner">Details</button>))

    # Without the context there is no Details tab (nothing to go back to).
    plain = ComposeDashboard.file_editor_fragment(
      "webapp", ComposeDashboard::StackFile::ComposeYaml, "/opt/webapp/compose.yaml", "x",
    )
    plain.should_not contain(">Details</button>")
  end

  it "branches Service logs on the container's log driver" do
    # journald driver: the full log view, filtered by container.
    journald = ComposeDashboard.service_details_fragment(SERVICES[0], false)
    journald.should contain("setContainerFilterAndTrigger")
    journald.should_not contain("compose-logs")

    # json-file driver: the plain tail plus an explanatory hint.
    json_file = ComposeDashboard.service_details_fragment(SERVICES[1], false)
    json_file.should contain("compose-logs?stack=webapp&amp;service=api")
    json_file.should contain("json-file")
    json_file.should contain("journald log driver")
    json_file.should_not contain("setContainerFilterAndTrigger")
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
    fragment.should contain("Discard changes")
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

  it "renders the service-logs jump" do
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
