require "./spec_helper"
require "file_utils"

# Each spec gets a fresh temp data dir, removed afterwards.
def with_tunnel_root(&block : String -> Nil)
  root = File.tempname("grafito-tunnel-spec")
  Dir.mkdir_p(root)
  begin
    block.call(root)
  ensure
    FileUtils.rm_rf(root)
  end
end

describe TunnelSettings do
  it "roundtrips settings through the JSON file with tight permissions" do
    with_tunnel_root do |root|
      settings = tunnel_settings
      TunnelSettings.save(root, settings)

      perms = File.info(TunnelSettings.path(root)).permissions
      {perms.owner_read?, perms.owner_write?}.should eq({true, true})
      {perms.group_read?, perms.other_read?}.should eq({false, false})

      loaded = TunnelSettings.load(root)
      loaded.should_not be_nil
      loaded.try(&.tunnel_id).should eq("f0f0f0f0-1111-2222-3333-444444444444")
      loaded.try(&.tunnel_name).should eq("grafito")
      loaded.try(&.credentials).should eq(%q({"AccountTag":"acct","TunnelSecret":"sekrit"}))
      loaded.try(&.enabled?).should be_true
    end
  end

  it "returns nil settings when nothing was saved" do
    with_tunnel_root do |root|
      TunnelSettings.load(root).should be_nil
    end
  end

  it "treats a settings pair as configured only with both ID and credentials" do
    TunnelSettings::Settings.new.configured?.should be_false
    TunnelSettings::Settings.new(tunnel_id: "abc").configured?.should be_false
    TunnelSettings::Settings.new(credentials: %q({"TunnelSecret":"s"})).configured?.should be_false
    tunnel_settings.configured?.should be_true
  end

  describe ".render_tunnel_config" do
    it "renders one ingress rule per routed app plus the catch-all" do
      routes = [
        AccessPanel::ProxyRoute.new(domain: "atuin.home.example.com", app_name: "Atuin", port: 8380),
        # Outside the base domain: the tunnel routes it anyway, unlike
        # the caddy path — the tunnel serves whatever DNS points at it.
        AccessPanel::ProxyRoute.new(domain: "elsewhere.example.org", app_name: "Other", port: 7000),
      ]
      config = TunnelSettings.render_tunnel_config(routes, "f0f0f0f0-1111-2222-3333-444444444444")
      config.should contain("tunnel: f0f0f0f0-1111-2222-3333-444444444444")
      config.should contain("credentials-file: /etc/cloudflared/credentials.json")
      config.should contain("- hostname: atuin.home.example.com")
      config.should contain("service: http://localhost:8380")
      config.should contain("- hostname: elsewhere.example.org")
      config.should contain("service: http://localhost:7000")
      # The mandatory catch-all comes last.
      config.should contain("- service: http_status:404")
      config.rindex("http_status:404").should_not be_nil
      config.rindex("http_status:404").should eq(config.index("http_status:404"))
    end

    it "renders only the catch-all when no apps are routed" do
      config = TunnelSettings.render_tunnel_config([] of AccessPanel::ProxyRoute, "abc")
      config.should_not contain("hostname:")
      config.should contain("- service: http_status:404")
    end
  end

  describe ".render_tunnel_compose" do
    it "runs cloudflared on the host network with the config and credentials mounted" do
      compose = TunnelSettings.render_tunnel_compose
      compose.should contain("cloudflare/cloudflared:latest")
      compose.should contain("container_name: grafito-tunnel")
      compose.should contain("network_mode: host")
      compose.should contain("--no-autoupdate")
      compose.should contain("./config.yml:/etc/cloudflared/config.yml:ro")
      compose.should contain("./credentials.json:/etc/cloudflared/credentials.json:ro")
    end
  end

  describe ".sync_tunnel_files" do
    it "writes the files from the routed apps and only rewrites on change" do
      with_tunnel_root do |root|
        with_tunnel_installed_app(root, "official", "atuin", "Atuin", 8380, "atuin.home.example.com") do
          settings = tunnel_settings

          first = TunnelSettings.sync_tunnel_files(root, settings)
          first.should be_true
          config = File.read(File.join(root, "tunnel", "config.yml"))
          config.should contain("- hostname: atuin.home.example.com")
          config.should contain("service: http://localhost:8380")
          File.exists?(File.join(root, "tunnel", "docker-compose.yml")).should be_true

          credentials_path = File.join(root, "tunnel", "credentials.json")
          File.read(credentials_path).should eq(%q({"AccountTag":"acct","TunnelSecret":"sekrit"}))
          perms = File.info(credentials_path).permissions
          {perms.group_read?, perms.other_read?}.should eq({false, false})

          # Same world, same files: nothing is rewritten.
          TunnelSettings.sync_tunnel_files(root, settings).should be_false
        end
      end
    end

    it "does not write a credentials file for empty credentials" do
      with_tunnel_root do |root|
        settings = TunnelSettings::Settings.new(tunnel_id: "abc")
        TunnelSettings.sync_tunnel_files(root, settings).should be_true
        File.exists?(File.join(root, "tunnel", "credentials.json")).should be_false
      end
    end
  end
end
