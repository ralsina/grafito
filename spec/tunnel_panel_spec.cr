require "./spec_helper"
require "file_utils"

# Named differently from compose_appstore_routes_spec's FORM_HEADERS:
# spec files compile into one program, and that one only exists in
# demo builds.
TUNNEL_FORM_HEADERS = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}

describe TunnelPanel do
  describe "routes" do
    # Demo builds open every action by design, so the gate only holds
    # in normal builds.
    {% unless flag?(:demo_mode) %}
      it "rejects tunnel endpoints without actions + auth" do
        Grafito.compose_enabled = true
        Grafito.enable_actions = false
        Grafito.auth_configured_override = false

        dispatch_request("POST", "/tunnel/settings", "tunnel_id=abc", TUNNEL_FORM_HEADERS)[:status].should eq(403)
        dispatch_request("POST", "/tunnel/start", "", TUNNEL_FORM_HEADERS)[:status].should eq(403)
        dispatch_request("POST", "/tunnel/stop", "", TUNNEL_FORM_HEADERS)[:status].should eq(403)
      end
    {% end %}

    it "saves settings, keeping the saved credentials when the field is blank" do
      Grafito.compose_enabled = true
      Grafito.enable_actions = true
      Grafito.auth_configured_override = true

      root = File.tempname("grafito-tunnel-panel-spec")
      Dir.mkdir_p(root)
      Grafito.data_dir = root
      begin
        response = dispatch_request(
          "POST", "/tunnel/settings",
          "enabled=true&tunnel_id=abc-123&tunnel_name=grafito&credentials=%7B%22TunnelSecret%22%3A%22s%22%7D",
          TUNNEL_FORM_HEADERS,
        )
        response[:status].should eq(200)
        response[:body].should contain("Tunnel settings saved.")

        saved = TunnelSettings.load(root)
        saved.should_not be_nil
        saved.try(&.tunnel_id).should eq("abc-123")
        saved.try(&.tunnel_name).should eq("grafito")
        saved.try(&.enabled?).should be_true
        saved.try(&.credentials).should eq(%q({"TunnelSecret":"s"}))

        # Re-save with a blank credentials field: the secret survives.
        response = dispatch_request(
          "POST", "/tunnel/settings",
          "enabled=true&tunnel_id=abc-123&tunnel_name=other-name&credentials=",
          TUNNEL_FORM_HEADERS,
        )
        response[:status].should eq(200)
        saved = TunnelSettings.load(root)
        saved.try(&.tunnel_name).should eq("other-name")
        saved.try(&.credentials).should eq(%q({"TunnelSecret":"s"}))
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "refuses to start or stop before settings are saved" do
      Grafito.compose_enabled = true
      Grafito.enable_actions = true
      Grafito.auth_configured_override = true

      root = File.tempname("grafito-tunnel-panel-spec")
      Dir.mkdir_p(root)
      Grafito.data_dir = root
      begin
        dispatch_request("POST", "/tunnel/start", "", TUNNEL_FORM_HEADERS)[:status].should eq(400)
        dispatch_request("POST", "/tunnel/stop", "", TUNNEL_FORM_HEADERS)[:status].should eq(400)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  describe ".tunnel_section" do
    it "renders the settings form, ingress table, DNS hint and explainer" do
      root = File.tempname("grafito-tunnel-panel-spec")
      Dir.mkdir_p(root)
      Grafito.data_dir = root
      begin
        with_tunnel_installed_app(root, "official", "atuin", "Atuin", 8380, "atuin.home.example.com") do
          with_tunnel_installed_app(root, "official", "other", "Other", 7000, "elsewhere.example.org") do
            settings = tunnel_settings
            fragment = TunnelPanel.tunnel_section(settings, "home.example.com")

            fragment.should contain("Cloudflare Tunnel")
            fragment.should contain("Tunnel ID")
            fragment.should contain("(saved — leave blank to keep)")
            fragment.should contain("start tunnel")
            # Every routed app is ingress, not only the base-domain ones.
            fragment.should contain("atuin.home.example.com")
            fragment.should contain("elsewhere.example.org")
            fragment.should contain("localhost:8380")
            fragment.should contain("needs its own DNS record")
            # The one-time wildcard CNAME hint.
            fragment.should contain("*.home.example.com")
            fragment.should contain("f0f0f0f0-1111-2222-3333-444444444444.cfargotunnel.com")
            # The teach-the-commands explainer.
            fragment.should contain("How this works, in shell commands")
            fragment.should contain("cloudflared tunnel create grafito")
            fragment.should contain("--project-name grafito-tunnel")
          end
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "points the way to the dashboard when not configured yet" do
      fragment = TunnelPanel.tunnel_section(TunnelSettings::Settings.new, "")
      fragment.should contain("Zero Trust")
      fragment.should_not contain("start tunnel")
    end
  end

  it "appears in the access panel" do
    settings = ProxySettings::Settings.new(
      enabled: false, base_domain: "home.example.com", email: "admin@example.com",
      dns_provider: "cloudflare",
    )
    fragment = AccessPanel.panel_fragment(settings)
    fragment.should contain("Cloudflare Tunnel — managed cloudflared")
    fragment.should contain("Save tunnel settings")
  end
end
