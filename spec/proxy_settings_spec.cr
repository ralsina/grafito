require "./spec_helper"
require "file_utils"

# Each spec gets a fresh temp data dir, removed afterwards.
def with_proxy_root(&block : String -> Nil)
  root = File.tempname("grafito-proxy-spec")
  Dir.mkdir_p(root)
  begin
    block.call(root)
  ensure
    FileUtils.rm_rf(root)
  end
end

def base_settings : ProxySettings::Settings
  ProxySettings::Settings.new(
    enabled: true,
    base_domain: "home.example.com",
    email: "admin@example.com",
    dns_provider: "cloudflare",
    credentials: {"CLOUDFLARE_DNS_API_TOKEN" => "token-123"} of String => String,
  )
end

describe ProxySettings do
  it "roundtrips settings through the JSON file with tight permissions" do
    with_proxy_root do |root|
      settings = base_settings
      ProxySettings.save(root, settings)

      perms = File.info(ProxySettings.path(root)).permissions
      {perms.owner_read?, perms.owner_write?}.should eq({true, true})
      {perms.group_read?, perms.other_read?}.should eq({false, false})

      loaded = ProxySettings.load(root)
      loaded.should_not be_nil
      loaded.try(&.base_domain).should eq("home.example.com")
      loaded.try(&.credentials["CLOUDFLARE_DNS_API_TOKEN"]).should eq("token-123")
    end
  end

  it "returns nil settings when nothing was saved" do
    with_proxy_root do |root|
      ProxySettings.load(root).should be_nil
    end
  end

  it "builds lego arguments for obtain and renew" do
    settings = base_settings
    run_args = ProxySettings.lego_args(settings, "/data", "run")
    run_args.should eq([
      "--email", "admin@example.com",
      "--dns", "cloudflare",
      "-d", "home.example.com",
      "-d", "*.home.example.com",
      "--path", "/data/lego",
      "run", "--accept-tos",
    ])

    renew_args = ProxySettings.lego_args(settings, "/data", "renew")
    renew_args.should contain("--days")
    renew_args.last.should eq("--accept-tos")
  end

  it "merges provider credentials into the lego environment" do
    env = ProxySettings.lego_env(base_settings)
    env["CLOUDFLARE_DNS_API_TOKEN"].should eq("token-123")
    env["PATH"]?.should_not be_nil # parent environment preserved
  end

  it "maps providers to their credential env variable" do
    ProxySettings.credential_env("cloudflare").should eq("CLOUDFLARE_DNS_API_TOKEN")
    ProxySettings.credential_env("duckdns").should eq("DUCKDNS_TOKEN")
    ProxySettings.credential_env("custom").should eq("LEGO_PROVIDER_CREDENTIALS")
  end

  it "detects renewal as due without a certificate and not due with a fresh one" do
    with_proxy_root do |root|
      settings = base_settings
      ProxySettings.renewal_due?(root, settings).should be_true

      key = ProxySettings.key_path(root, settings.base_domain)
      cert = ProxySettings.cert_path(root, settings.base_domain)
      Dir.mkdir_p(File.dirname(cert))
      `openssl req -x509 -newkey rsa:2048 -keyout #{key} -out #{cert} -days 90 -nodes -subj "/CN=home.example.com" 2>/dev/null`

      ProxySettings.renewal_due?(root, settings).should be_false

      expiring = ProxySettings.cert_expiry(cert)
      expiring.should_not be_nil
    end
  end

  it "renders the settings panel with fields and cert status" do
    settings = base_settings
    fragment = AccessPanel.panel_fragment(settings, saved: true)

    fragment.should contain("Access &amp; domains")
    fragment.should contain("Base domain (apps become app.base_domain)")
    fragment.should contain("home.example.com")
    fragment.should contain("DNS provider (for the DNS-01 challenge)")
    fragment.should contain("Settings saved.")
    fragment.should contain("not issued yet")
    # host:port baseline stays front and center.
    fragment.should contain("http://host:port")
  end
end
