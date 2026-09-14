require "./spec_helper"

# ComposeStatus specs. The JSON fixtures mirror what `docker compose ls
# --format json` and `docker ps --format '{{json .}}'` actually emit, so
# the parsing logic is tested against real shapes without docker.

private LS_FIXTURE = <<-JSON
  [
    {"Name": "webapp", "Status": "running(3)", "ConfigFiles": "/opt/stacks/webapp/compose.yaml"},
    {"Name": "monitoring", "Status": "exited(1)", "ConfigFiles": "/opt/stacks/monitoring/compose.yaml, /opt/stacks/monitoring/compose.override.yaml"},
    {"Name": "", "Status": "running(1)", "ConfigFiles": ""}
  ]
  JSON

private PS_FIXTURE = <<-LINES
  {"Names":"webapp-web-1","Image":"nginx:1.27-alpine","State":"running","Status":"Up 3 days (healthy)","Ports":"0.0.0.0:8080->80/tcp","Labels":{"com.docker.compose.project":"webapp","com.docker.compose.service":"web"}}
  {"Names":"webapp-db-1","Image":"postgres:16-alpine","State":"running","Status":"Up 3 days (healthy)","Ports":"127.0.0.1:5432->5432/tcp","Labels":{"com.docker.compose.project":"webapp","com.docker.compose.service":"db"}}
  {"Names":"monitoring-vector-1","Image":"timberio/vector:latest","State":"exited","Status":"Exited (0) 5 minutes ago","Ports":"","Labels":{"com.docker.compose.project":"monitoring","com.docker.compose.service":"vector"}}
  {"Names":"orphan-1","Image":"example/app:1.0","State":"running","Status":"Up 1 minute","Ports":"","Labels":{"com.docker.compose.project":"orphan","com.docker.compose.service":"app"}}
  {"Names":"lonely","Image":"alpine","State":"running","Status":"Up 1 minute","Ports":"","Labels":{}}
  LINES

describe ComposeStatus do
  it "parses docker compose ls output" do
    meta = ComposeStatus.parse_stack_meta(LS_FIXTURE)
    meta.size.should eq(2)
    meta[0][:name].should eq("webapp")
    meta[0][:status].should eq("running(3)")
    meta[0][:config_files].should eq(["/opt/stacks/webapp/compose.yaml"])
    # Multiple config files come comma-separated.
    meta[1][:config_files].should eq([
      "/opt/stacks/monitoring/compose.yaml",
      "/opt/stacks/monitoring/compose.override.yaml",
    ])
  end

  it "tolerates malformed compose ls output" do
    ComposeStatus.parse_stack_meta("not json").should be_empty
    ComposeStatus.parse_stack_meta("").should be_empty
  end

  it "parses docker ps output, ignoring non-compose containers" do
    containers = ComposeStatus.parse_containers(PS_FIXTURE)
    containers.size.should eq(5)
    containers[0].names.should eq("webapp-web-1")
    containers[0].labels_or_empty["com.docker.compose.project"].should eq("webapp")
    containers[4].labels_or_empty.should be_empty
  end

  it "tolerates malformed docker ps output" do
    ComposeStatus.parse_containers("not json\n{\"Names\":\"ok\",\"Image\":\"i\",\"State\":\"running\",\"Status\":\"Up\",\"Ports\":\"\",\"Labels\":{}}").size.should eq(1)
    ComposeStatus.parse_containers("").should be_empty
  end

  it "accepts null Ports and Labels, which docker emits for some containers" do
    containers = ComposeStatus.parse_containers(
      %({"Names":"bare","Image":"alpine","State":"running","Status":"Up 1 minute","Ports":null,"Labels":null}\n)
    )
    containers.size.should eq(1)
    containers[0].ports_or_empty.should eq("")
    containers[0].labels_or_empty.should be_empty
  end

  it "accepts Labels as a comma-joined string, as some docker CLIs emit" do
    containers = ComposeStatus.parse_containers(
      %({"Names":"str","Image":"alpine","State":"running","Status":"Up","Ports":"","Labels":"com.docker.compose.project=webapp,com.docker.compose.service=web"}\n)
    )
    containers.size.should eq(1)
    labels = containers[0].labels_or_empty
    labels["com.docker.compose.project"].should eq("webapp")
    labels["com.docker.compose.service"].should eq("web")
  end

  describe "Service" do
    it "classifies running and unhealthy services" do
      service = ComposeStatus::Service.new(
        stack: "webapp", service: "api", container: "webapp-api-1",
        state: "running", health: "unhealthy", image: "img:1",
        ports: "", status_text: "Up 2 hours (unhealthy)",
      )
      service.running?.should be_true
      service.unhealthy?.should be_true

      stopped = ComposeStatus::Service.new(
        stack: "webapp", service: "api", container: "webapp-api-1",
        state: "exited", health: "", image: "img:1",
        ports: "", status_text: "Exited (0) 5 minutes ago",
      )
      stopped.running?.should be_false
      stopped.unhealthy?.should be_false
    end
  end

  describe "Stack" do
    it "counts running and unhealthy services" do
      compose_stack = stack_with(["/opt/stacks/webapp/compose.yaml"])
      compose_stack.running_count.should eq(1)
      compose_stack.unhealthy_count.should eq(1)
    end

    it "is only actionable when config files are known" do
      stack_with(["/opt/stacks/webapp/compose.yaml"]).actionable?.should be_true
      stack_with([] of String).actionable?.should be_false
    end
  end

  it "does not find unknown stacks or services" do
    # No docker fixture needed: impossible names never exist, in fake
    # mode or on a real host.
    ComposeStatus.find_stack("this-stack-does-not-exist-42").should be_nil
    ComposeStatus.find_service("this-stack-does-not-exist-42", "nope").should be_nil
  end

  {% if flag?(:fake_journal) %}
    it "provides fake stacks for the demo build" do
      stacks = ComposeStatus.stacks
      stacks.size.should be > 0
      webapp = stacks.find(&.name.==("webapp"))
      webapp.should_not be_nil
      if webapp
        webapp.actionable?.should be_true
        webapp.services.size.should eq(3)
        webapp.unhealthy_count.should eq(1)
      end
      FakeComposeData.compose_yaml("webapp").should contain("services:")
    end
  {% end %}
end

private def stack_with(config_files : Array(String)) : ComposeStatus::Stack
  ComposeStatus::Stack.new(
    name: "webapp", status: "running(1)", config_files: config_files,
    services: [
      ComposeStatus::Service.new(
        stack: "webapp", service: "web", container: "c1",
        state: "running", health: "unhealthy", image: "img:1",
        ports: "", status_text: "Up (unhealthy)",
      ),
    ],
  )
end
