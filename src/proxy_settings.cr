# # Proxy settings
#
# Configuration and certificate management for the access layer's
# TLS termination: the wildcard `*.<base domain>` certificate is
# obtained and renewed with the **lego** binary (DNS-01, so no ports
# need to face the internet), and the resulting files are what the
# managed caddy stack (#138 PR 3) serves.
#
# Settings live in `<data-dir>/proxy-settings.json` (0600 — they hold
# a DNS provider API token). Renewal runs from a background fiber
# when the certificate has less than RENEW_BEFORE_DAYS left.

require "json"
require "log"
require "time"

module ProxySettings
  Log = ::Log.for(self)

  extend self

  RENEW_BEFORE_DAYS = 30

  DNS_PROVIDERS = ["cloudflare", "digitalocean", "duckdns", "route53", "gandi"]

  class Settings
    include JSON::Serializable

    property? enabled : Bool = false
    property base_domain : String = ""
    property email : String = ""
    property dns_provider : String = "cloudflare"
    property credentials : Hash(String, String) = {} of String => String
    property lego_path : String = "/usr/bin/lego"

    def initialize(
      enabled : Bool = false,
      base_domain : String = "",
      email : String = "",
      dns_provider : String = "cloudflare",
      credentials : Hash(String, String) = {} of String => String,
      lego_path : String = DEFAULT_LEGO_PATH,
    )
      @enabled = enabled
      @base_domain = base_domain
      @email = email
      @dns_provider = dns_provider
      @credentials = credentials
      @lego_path = lego_path
    end
  end

  DEFAULT_LEGO_PATH = "/usr/bin/lego"

  # ## Storage

  def self.path(data_dir : String) : String
    File.join(data_dir, "proxy-settings.json")
  end

  def self.load(data_dir : String) : Settings?
    path = path(data_dir)
    return unless File.file?(path)
    Settings.from_json(File.read(path))
  rescue ex
    Log.error(exception: ex) { "Failed to read #{path}" }
    nil
  end

  # Persists settings with owner-only permissions: the file holds a
  # DNS provider API token.
  def self.save(data_dir : String, settings : Settings) : Nil
    path = path(data_dir)
    File.write(path, settings.to_pretty_json, perm: 0o600)
    File.chmod(path, 0o600)
  rescue ex
    Log.error(exception: ex) { "Failed to save #{path}" }
  end

  # ## lego

  # The lego working directory: archives + certificates/<base domain>.
  def self.lego_dir(data_dir : String) : String
    File.join(data_dir, "lego")
  end

  def self.cert_path(data_dir : String, base_domain : String) : String
    File.join(lego_dir(data_dir), "certificates", "#{base_domain}.crt")
  end

  def self.key_path(data_dir : String, base_domain : String) : String
    File.join(lego_dir(data_dir), "certificates", "#{base_domain}.key")
  end

  # Builds the lego invocation for obtaining (action "run") or
  # renewing (action "renew") the wildcard certificate. Pure: specs
  # assert on it.
  def self.lego_args(settings : Settings, data_dir : String, action : String) : Array(String)
    args = [
      "--email", settings.email,
      "--dns", settings.dns_provider,
      "-d", settings.base_domain,
      "-d", "*.#{settings.base_domain}",
      "--path", lego_dir(data_dir),
    ]
    args << "--days" << RENEW_BEFORE_DAYS.to_s if action == "renew"
    args + [action, "--accept-tos"]
  end

  # The environment lego needs: the parent process plus the provider
  # credentials (e.g. CLOUDFLARE_DNS_API_TOKEN).
  def self.lego_env(settings : Settings) : Hash(String, String)
    ENV.to_h.merge(settings.credentials)
  end

  # The env variable lego reads the provider credential from. Only
  # the built-in providers map here; "custom" assumes the user set
  # the variables in the environment already.
  def self.credential_env(provider : String) : String
    case provider
    when "cloudflare"   then "CLOUDFLARE_DNS_API_TOKEN"
    when "digitalocean" then "DIGITALOCEAN_ACCESS_TOKEN"
    when "duckdns"      then "DUCKDNS_TOKEN"
    when "route53"      then "AWS_ACCESS_KEY_ID"
    when "gandi"        then "GANDI_API_TOKEN"
    else                     "LEGO_PROVIDER_CREDENTIALS"
    end
  end

  # Runs lego (blocking) and returns its combined output. Best-effort:
  # failures are returned as output with success: false.
  def self.run_lego(settings : Settings, data_dir : String, action : String) : NamedTuple(success: Bool, output: String)
    unless DNS_PROVIDERS.includes?(settings.dns_provider) || settings.dns_provider == "custom"
      return {success: false, output: "Unknown DNS provider '#{settings.dns_provider}'."}
    end
    if settings.credentials.empty? && settings.dns_provider != "custom"
      return {success: false, output: "No DNS provider credentials configured — add the API token in the settings form."}
    end

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    result = Process.run(settings.lego_path, args: lego_args(settings, data_dir, action),
      output: stdout, error: stderr, env: lego_env(settings))
    output = "#{stdout}\n#{stderr}".strip
    {success: result.success?, output: output.empty? ? "lego finished with no output." : output}
  rescue File::NotFoundError
    {success: false, output: "lego binary not found at '#{settings.lego_path}' (install it or set --lego-bin)."}
  rescue ex
    {success: false, output: "lego failed: #{ex.message}"}
  end

  # ## Certificate state

  # Reads the certificate's expiry with openssl. Nil when unreadable.
  def self.cert_expiry(cert_path : String) : Time?
    stdout = IO::Memory.new
    result = Process.run("openssl", args: ["x509", "-in", cert_path, "-noout", "-enddate"],
      output: stdout, error: Process::Redirect::Close)
    return unless result.success?
    # "notAfter=Mar 18 12:00:00 2027 GMT" — openssl pads single-digit
    # days with a space, so normalize whitespace before parsing. Parse
    # in UTC: lego/LE certificates are always GMT.
    value = stdout.to_s.strip.lchop("notAfter=").split(" ").reject(&.empty?).join(" ").lchop("notAfter=")
    Time.parse(value, "%b %d %H:%M:%S %Y", Time::Location::UTC)
  rescue ex
    Log.warn(exception: ex) { "Could not read certificate expiry from #{cert_path}" }
    nil
  end

  # True when there is no certificate yet or it expires within
  # RENEW_BEFORE_DAYS.
  def self.renewal_due?(data_dir : String, settings : Settings) : Bool
    cert = cert_path(data_dir, settings.base_domain)
    expiry = cert_expiry(cert) if File.file?(cert)
    expiry.nil? || expiry <= Time.utc + RENEW_BEFORE_DAYS.days
  end
end
