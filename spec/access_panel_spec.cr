require "./spec_helper"
require "file_utils"

# Renders one installed app record on disk (app.json), the way the
# app store writes it, so route derivation has something to read.
def with_installed_app(root : String, store : String, id : String, name : String, port : Int32, domain : String = "", &)
  dir = File.join(root, "apps", store, id)
  Dir.mkdir_p(dir)
  record = AppStore::InstalledApp.new(
    store: store, id: id, name: name, version: "1.0",
    tipi_version: 1, port: port, project_name: id,
    installed_at: Time.utc.to_rfc3339, domain: domain,
  )
  File.write(File.join(dir, "app.json"), record.to_pretty_json)
  yield AppStore::InstalledApp.new(
    store: store, id: id, name: name, version: "1.0",
    tipi_version: 1, port: port, project_name: id,
    installed_at: Time.utc.to_rfc3339, domain: domain,
  )
  FileUtils.rm_rf(File.join(root, "apps", store, id))
end

describe AccessPanel do
  describe ".routes" do
    it "derives routes from installed apps with a domain, sorted by domain" do
      root = File.tempname("grafito-access-spec")
      Dir.mkdir_p(root)
      begin
        routes = [] of AccessPanel::ProxyRoute
        with_installed_app(root, "official", "jellyfin", "Jellyfin", 8096, "media.home.example.com") do
          with_installed_app(root, "official", "atuin", "Atuin", 8380, "atuin.home.example.com") do
            with_installed_app(root, "official", "headless", "Headless", 9000) do
              routes = AccessPanel.routes(root)
            end
          end
        end
        routes.size.should eq(2) # headless has no domain: not routed
        routes[0].domain.should eq("atuin.home.example.com")
        routes[0].port.should eq(8380)
        routes[1].domain.should eq("media.home.example.com")
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  describe ".render_caddyfile" do
    it "renders one site block per routed app with the wildcard TLS files" do
      routes = [
        AccessPanel::ProxyRoute.new(domain: "atuin.home.example.com", app_name: "Atuin", port: 8380),
        AccessPanel::ProxyRoute.new(domain: "media.home.example.com", app_name: "Jellyfin", port: 8096),
        # Not under the base domain: skipped (wildcard doesn't cover it).
        AccessPanel::ProxyRoute.new(domain: "elsewhere.example.org", app_name: "Other", port: 7000),
      ]
      caddyfile = AccessPanel.render_caddyfile(routes, "home.example.com", "/data")
      caddyfile.scan(/^[\w.-]+ \{/m).size.should eq(2)
      caddyfile.should contain("atuin.home.example.com {")
      caddyfile.should contain("tls /data/lego/certificates/home.example.com.crt /data/lego/certificates/home.example.com.key")
      caddyfile.should contain("reverse_proxy 127.0.0.1:8380")
      caddyfile.should_not contain("elsewhere.example.org")
    end
  end

  describe ".render_proxy_compose" do
    it "runs caddy on the host network with the certs and config mounted" do
      compose = AccessPanel.render_proxy_compose("/data")
      compose.should contain("caddy:2")
      compose.should contain("network_mode: host")
      compose.should contain("./Caddyfile:/etc/caddy/Caddyfile:ro")
      compose.should contain("../lego:/certs:ro")
    end
  end
end
