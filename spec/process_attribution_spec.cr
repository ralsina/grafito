require "./spec_helper"
require "../src/process_status"
require "../src/compose_status"
require "../src/process_dashboard"

# cgroup -> docker container -> compose stack/service attribution (#91).
# The pure pieces: container ID extraction from /proc/PID/cgroup lines,
# the container-ID -> stack/service map built from docker ps JSON, and
# the process table's badge + filter over the attribution.
describe "Process compose attribution" do
  describe "ProcessStatus.container_id_from_cgroup_lines" do
    it "extracts the id from a cgroup v2 systemd scope" do
      id64 = "0123456789abcdef" * 4
      lines = ["0::/system.slice/docker-#{id64}.scope"]
      ProcessStatus.container_id_from_cgroup_lines(lines).should eq(id64)
    end

    it "extracts the id from a cgroup v1 cgroupfs path" do
      id64 = "fedcba9876543210" * 4
      lines = ["9:cpuset:/docker/#{id64}"]
      ProcessStatus.container_id_from_cgroup_lines(lines).should eq(id64)
    end

    it "returns nil for non-container processes" do
      lines = ["0::/system.slice/nginx.service", "10:cpu:/user.slice/user-1000.slice"]
      ProcessStatus.container_id_from_cgroup_lines(lines).should be_nil
    end
  end

  describe "ComposeStatus.attribution_from_containers" do
    full_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    ref = ComposeStatus::ContainerRef.new(stack: "webapp", service: "web")

    it "keys the map by full and 12-char container id" do
      json_line = %({"ID":"#{full_id}","Names":"webapp-web-1","Image":"nginx:1.27","State":"running","Status":"Up 2 hours","Labels":{"com.docker.compose.project":"webapp","com.docker.compose.service":"web"}})
      containers = ComposeStatus.parse_containers(json_line)

      map = ComposeStatus.attribution_from_containers(containers)
      map[full_id].should eq(ref)
      map[full_id[0, 12]].should eq(ref)
    end

    it "ignores non-running containers" do
      exited_id = "fedcba9876543210" * 4
      json_line = %({"ID":"#{exited_id}","Names":"webapp-db-1","Image":"postgres:16","State":"exited","Labels":{"com.docker.compose.project":"webapp","com.docker.compose.service":"db"}})
      ComposeStatus.attribution_from_containers(ComposeStatus.parse_containers(json_line)).should be_empty
    end
  end

  describe "ProcessDashboard rendering and filtering" do
    attributed = ProcessStatus::ProcessInfo.new(
      pid: 4242, user: "www-data", cpu_pct: 2.0, mem_pct: 1.0,
      virt_kb: 100_000, res_kb: 20_000, state: "S", cpu_time_sec: 12.0,
      command: "nginx: worker process",
      compose_stack: "webapp", compose_service: "web",
    )
    plain = ProcessStatus::ProcessInfo.new(
      pid: 4243, user: "root", cpu_pct: 0.1, mem_pct: 0.1,
      virt_kb: 10_000, res_kb: 5_000, state: "S", cpu_time_sec: 1.0,
      command: "/sbin/init splash",
    )
    snapshot = ProcessStatus::Snapshot.new(
      timestamp: Time.local, cpu_count: 4, core_pcts: [1.0, 2.0, 3.0, 4.0],
      load1: 0.5, mem_total_kb: 1_000_000, mem_used_kb: 100_000,
      tasks_total: 2, tasks_running: 0,
      processes: [attributed, plain],
    )

    it "shows the compose badge for attributed processes" do
      html = ProcessDashboard.render_html(snapshot, limit: "all")
      html.should contain("webapp/web")
      html.should contain("proc-compose-tag")
    end

    it "filters by stack and service names" do
      filtered = ProcessDashboard.render_html(snapshot, filter: "webapp", limit: "all")
      filtered.should contain("4242")
      filtered.should_not contain("4243")

      by_service = ProcessDashboard.render_html(snapshot, filter: "web", limit: "all")
      by_service.should contain("4242")
    end

    it "keeps unattributed processes out of the compose filter" do
      no_match = ProcessDashboard.render_html(snapshot, filter: "no-such-stack-zzz", limit: "all")
      no_match.should contain("0 of")
    end
  end
end

describe "Compose service detail member processes (#93)" do
  member = ProcessStatus::ProcessInfo.new(
    pid: 4242, user: "www-data", cpu_pct: 2.0, mem_pct: 1.0,
    virt_kb: 100_000, res_kb: 20_000, state: "S", cpu_time_sec: 12.0,
    command: "nginx: worker process",
    compose_stack: "webapp", compose_service: "web",
  )
  service = ComposeStatus::Service.new(
    stack: "webapp", service: "web", container: "webapp-web-1",
    state: "running", health: "healthy", image: "nginx:1.27",
    ports: "80/tcp", status_text: "Up 2 hours",
  )

  it "lists member processes with live stats" do
    fragment = ComposeDashboard.service_details_fragment(service, false, [member])
    fragment.should contain("Processes")
    fragment.should contain("PID 4242")
    fragment.should contain("nginx: worker process")
    fragment.should contain("CPU 2.0%")
    fragment.should contain("live from the process monitor")
  end

  it "omits the section when the service has no member processes" do
    fragment = ComposeDashboard.service_details_fragment(service, false, [] of ProcessStatus::ProcessInfo)
    fragment.should_not contain("Processes")
  end
end

describe "Process detail compose jump (#92)" do
  attributed = ProcessStatus::ProcessDetail.new(
    pid: 4242, user: "www-data", uid: "33", state: "S", cpu_pct: 2.0,
    mem_pct: 1.0, virt_kb: 100_000, res_kb: 20_000, cpu_time_sec: 12.0,
    threads: 1, ppid: 1, started: Time.local, command: "nginx: worker process",
    unit: "", compose_stack: "webapp", compose_service: "web",
  )

  it "offers the jump to the compose view for attributed processes" do
    fragment = ProcessDashboard.process_details_fragment(attributed, true)
    fragment.should contain("openComposeService")
    fragment.should contain("webapp")
  end

  it "keeps the jump out of unattributed processes" do
    unattributed = ProcessStatus::ProcessDetail.new(
      pid: 1, user: "root", uid: "0", state: "S", cpu_pct: 0.1,
      mem_pct: 0.1, virt_kb: 10_000, res_kb: 5_000, cpu_time_sec: 1.0,
      threads: 1, ppid: 0, started: Time.local, command: "/sbin/init",
      unit: "", compose_stack: nil, compose_service: nil,
    )
    fragment = ProcessDashboard.process_details_fragment(unattributed, true)
    fragment.should_not contain("openComposeService")
  end
end
