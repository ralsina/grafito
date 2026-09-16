require "./spec_helper"

# Exercises the REAL systemctl action path (#72): a failed `systemctl
# stop` must surface as an error, not render as success. Before the
# success? fix, a polkit denial (exit 1) was treated as a normal exit
# and the dashboard re-rendered as if the action had worked.
{% unless flag?(:demo_mode) %}
  describe "POST /unit/:name/:action (real systemctl path)" do
    fixture_dir = File.join(__DIR__, "fixtures")
    original_path = ENV["PATH"]

    around_each do |example|
      ENV["PATH"] = "#{fixture_dir}:#{original_path}"
      Grafito.enable_actions = true
      Grafito.auth_configured = true
      example.run
    ensure
      ENV.delete("FAKE_SYSTEMCTL_FAIL")
      ENV["PATH"] = original_path
      Grafito.enable_actions = false
      Grafito.auth_configured = false
    end

    it "surfaces systemctl failures instead of rendering success" do
      ENV["FAKE_SYSTEMCTL_FAIL"] = "1"
      response = dispatch_request("POST", "/unit/spec.service/stop")
      response[:status].should eq(500)
      response[:body].should contain("action denied by fake polkit")
    end

    it "renders the dashboard on success" do
      response = dispatch_request("POST", "/unit/spec.service/stop")
      response[:status].should eq(200)
    end

    it "refuses actions without enable-actions + auth" do
      Grafito.enable_actions = false
      Grafito.auth_configured = false
      response = dispatch_request("POST", "/unit/spec.service/stop")
      response[:status].should eq(403)
      response[:body].should contain("Unit actions are disabled")
    end
  end
{% end %}
