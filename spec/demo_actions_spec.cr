require "./spec_helper"

# Demo builds simulate every action against the mutable fake world:
# stopping a unit really shows it as dead, installing a store app
# really creates a stack, killing a process really removes it. These
# specs exercise those simulations end to end, so they only make sense
# with -Ddemo_mode.
{% if flag?(:demo_mode) %}
  describe "demo action simulations" do
    # Insurance against leaked state from other spec files: every test
    # below also resets in ensure.
    SystemStatus.reset_demo_state
    FakeComposeData.reset_demo_state
    FakeAppStore.reset_demo_state
    ProcessStatus.reset_demo_state

    it "reports demo mode and available actions" do
      Grafito.demo_mode?.should be_true
      Grafito.actions_available?.should be_true
    end

    it "simulates stopping and starting a unit" do
      response = dispatch_request("POST", "/unit/nginx.service/stop")
      response[:status].should eq(200)

      stopped = SystemStatus.unit_states.find(&.unit.==("nginx.service"))
      stopped.should_not be_nil
      if unit_state = stopped
        unit_state.active_state.should eq("inactive")
        unit_state.sub_state.should eq("dead")
      end

      # The dashboard JSON reflects the simulated state.
      status_response = dispatch_request("GET", "/status")
      status_response[:body].should contain("\"active_state\":\"inactive\"")

      # The refreshed panel (from=panel) shows the stopped state too.
      panel = dispatch_request("POST", "/unit/nginx.service/stop?from=panel")
      panel[:status].should eq(200)
      panel[:body].should contain("inactive")

      start_response = dispatch_request("POST", "/unit/nginx.service/start")
      start_response[:status].should eq(200)
      started = SystemStatus.unit_states.find(&.unit.==("nginx.service"))
      if unit_state = started
        unit_state.active_state.should eq("active")
      end
    ensure
      SystemStatus.reset_demo_state
    end

    it "simulates recovering a failed unit by starting it" do
      response = dispatch_request("POST", "/unit/fake-broken.service/start")
      response[:status].should eq(200)

      recovered = SystemStatus.unit_states.find(&.unit.==("fake-broken.service"))
      if unit_state = recovered
        unit_state.failed?.should be_false
      end
    ensure
      SystemStatus.reset_demo_state
    end

    it "simulates enable and disable of a unit" do
      dispatch_request("POST", "/unit/nginx.service/disable")[:status].should eq(200)
      SystemStatus.unit_flags_map["nginx.service"]?.try(&.file_state).should eq("disabled")

      dispatch_request("POST", "/unit/nginx.service/enable")[:status].should eq(200)
      SystemStatus.unit_flags_map["nginx.service"]?.try(&.file_state).should eq("enabled")
    ensure
      SystemStatus.reset_demo_state
    end

    it "simulates stopping and starting a compose stack" do
      response = dispatch_request("POST", "/compose-stack/webapp/stop")
      response[:status].should eq(200)
      response[:body].should contain("compose-output-webapp")

      stopped_stack = ComposeStatus.stacks.find(&.name.==("webapp"))
      stopped_stack.should_not be_nil
      if compose_stack = stopped_stack
        compose_stack.status.should eq("exited")
        compose_stack.services.all?(&.state.==("exited")).should be_true
      end

      up_response = dispatch_request("POST", "/compose-stack/webapp/up")
      up_response[:status].should eq(200)
      up_stack = ComposeStatus.stacks.find(&.name.==("webapp"))
      if compose_stack = up_stack
        compose_stack.services.all?(&.state.==("running")).should be_true
      end
    ensure
      FakeComposeData.reset_demo_state
    end

    it "simulates stopping and starting a single compose service" do
      response = dispatch_request("POST", "/compose-service/webapp/web/stop")
      response[:status].should eq(200)

      # Only the targeted service goes down; its stack mates stay up.
      web_service = ComposeStatus.find_service("webapp", "web")
      web_service.should_not be_nil
      if service = web_service
        service.state.should eq("exited")
        service.status_text.should eq("Exited (0) a few seconds ago")
      end
      db_service = ComposeStatus.find_service("webapp", "db")
      if service = db_service
        service.state.should eq("running")
      end

      # The detail panel reflects the simulated state.
      panel = dispatch_request("GET", "/compose-details?stack=webapp&service=web")
      panel[:body].should contain("Exited (0) a few seconds ago")

      start_response = dispatch_request("POST", "/compose-service/webapp/web/start")
      start_response[:status].should eq(200)
      ComposeStatus.find_service("webapp", "web").try(&.state).should eq("running")
    ensure
      FakeComposeData.reset_demo_state
    end

    it "simulates terminating a process" do
      before = ProcessStatus.snapshot.processes.size

      response = dispatch_request("POST", "/process/1240/term")
      response[:status].should eq(200)

      ProcessStatus.snapshot.processes.size.should eq(before - 1)
      ProcessStatus.snapshot.processes.any?(&.pid.==(1240)).should be_false
    ensure
      ProcessStatus.reset_demo_state
    end

    it "simulates pausing and resuming a process" do
      dispatch_request("POST", "/process/1666/stop")[:status].should eq(200)
      ProcessStatus.snapshot.processes.find(&.pid.==(1666)).try(&.state).should eq("T")

      dispatch_request("POST", "/process/1666/cont")[:status].should eq(200)
      ProcessStatus.snapshot.processes.find(&.pid.==(1666)).try(&.state).should_not eq("T")
    ensure
      ProcessStatus.reset_demo_state
    end

    it "refuses to signal init with a demo notice" do
      response = dispatch_request("POST", "/process/1/kill")
      response[:status].should eq(200)
      response[:body].should contain("This is demo mode")
      response[:body].should contain("init stays alive")
    end

    it "returns 404 for signals to unknown pids" do
      dispatch_request("POST", "/process/999999/term")[:status].should eq(404)
    end
  end
{% end %}
