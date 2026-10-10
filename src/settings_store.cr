# # Settings store
#
# The runtime-editable settings layer behind the settings view and the
# onboarding wizard. Everything the operator can change from the web
# UI lives in `<data-dir>/settings.json`; everything set at boot (CLI
# flag, `GRAFITO_*` environment variable or the `GRAFITO_CONFIG` yaml)
# keeps precedence and is shown read-only in the UI.
#
# The file holds basic-auth credentials, the display timezone, the AI
# provider/key/model and a homepage overlay (title, hostname, weather).
# Secrets are stored in plaintext inside a `0600` file, exactly like
# the DNS provider token in `proxy-settings.json`; grafito deliberately
# avoids adding a crypto dependency for this.
#
# Reads are per use (like the proxy settings and the homepage config:
# a small `File.read` per request) and writes are tmp+rename so a crash
# mid-write can never truncate the file. Demo builds never touch the
# disk: `load`/`save` route to the in-memory `FakeSettings`.

require "json"
require "log"
require "mutex"

module SettingsStore
  Log = ::Log.for(self)

  # AI provider settings. When the boot environment already names a
  # provider, key or model, the environment wins and these are ignored.
  class AISettings
    include JSON::Serializable

    property provider : String? = nil
    property api_key : String? = nil
    property model : String? = nil

    def initialize(@provider : String? = nil, @api_key : String? = nil, @model : String? = nil)
    end

    def set? : Bool
      !provider.nil? || !api_key.nil? || !model.nil?
    end
  end

  # Weather overrides for the homepage. Latitude and longitude only
  # take effect as a pair (coordinates are the whole point).
  class WeatherSettings
    include JSON::Serializable

    property latitude : Float64? = nil
    property longitude : Float64? = nil
    property location : String? = nil
    property units : String? = nil

    def initialize(@latitude : Float64? = nil, @longitude : Float64? = nil,
                   @location : String? = nil, @units : String? = nil)
    end
  end

  # Homepage basics the settings view can override on top of
  # homepage.yml (which keeps supplying the service groups).
  class HomepageSettings
    include JSON::Serializable

    property title : String? = nil
    property hostname : String? = nil
    property weather : WeatherSettings? = nil

    def initialize(@title : String? = nil, @hostname : String? = nil,
                   @weather : WeatherSettings? = nil)
    end

    def set? : Bool
      !title.nil? || !hostname.nil? || !weather.nil?
    end
  end

  class Settings
    include JSON::Serializable

    property auth_user : String? = nil
    property auth_pass : String? = nil
    property timezone : String? = nil
    property? onboarded : Bool = false
    property ai : AISettings? = nil
    property homepage : HomepageSettings? = nil

    def initialize(@auth_user : String? = nil, @auth_pass : String? = nil,
                   @timezone : String? = nil, @onboarded : Bool = false,
                   @ai : AISettings? = nil, @homepage : HomepageSettings? = nil)
    end
  end

  def self.path(data_dir : String) : String
    File.join(data_dir, "settings.json")
  end

  # Current settings. An unreadable file logs a warning and falls back
  # to defaults: broken settings should lock nobody out.
  def self.load(data_dir : String) : Settings
    {% if flag?(:demo_mode) %}
      FakeSettings.load
    {% else %}
      settings_path = path(data_dir)
      return Settings.new unless File.exists?(settings_path)
      Settings.from_json(File.read(settings_path))
    {% end %}
  rescue ex
    Log.warn { "Could not read #{path(data_dir)} (#{ex.message}); using default settings" }
    Settings.new
  end

  def self.save(data_dir : String, settings : Settings) : Nil
    {% if flag?(:demo_mode) %}
      FakeSettings.save(settings)
    {% else %}
      Dir.mkdir_p(data_dir)
      settings_path = path(data_dir)
      tmp = "#{settings_path}.tmp"
      File.write(tmp, settings.to_pretty_json, perm: 0o600)
      File.rename(tmp, settings_path)
    {% end %}
  end

  # ## Effective values

  # Credentials from the boot environment, or nil when unset (or, as
  # ever, when only one of the two was provided).
  def self.env_auth : {String, String}?
    auth_user = ENV["GRAFITO_AUTH_USER"]?
    auth_pass = ENV["GRAFITO_AUTH_PASS"]?
    return {auth_user, auth_pass} if auth_user && auth_pass
    nil
  end

  # The credentials requests are checked against: the boot
  # environment's when set, otherwise the settings file's.
  def self.effective_auth(data_dir : String = Grafito.data_dir) : {String, String}?
    return env_auth if env_auth
    settings = load(data_dir)
    auth_user = settings.auth_user
    auth_pass = settings.auth_pass
    return {auth_user, auth_pass} if auth_user && auth_pass
    nil
  end

  # True when the boot environment owns authentication, so the UI can
  # show the credentials section as environment-managed.
  def self.auth_from_env? : Bool
    !env_auth.nil?
  end

  # What the bridge last wrote into the environment: key → value.
  # Retraction only removes a key whose current value still is the
  # bridged one, so a value anyone else set in between survives.
  @@bridged_env_keys = {} of String => String
  @@bridge_mutex = Mutex.new

  # Applies the settings' AI configuration to the process environment
  # (only the keys the operator has NOT set) and returns whether
  # anything changed. Keys a previous call injected are retracted
  # first, so switching or disabling the settings provider takes
  # effect instead of being masked by stale values. Bridging into ENV
  # is deliberate: every provider and availability check reads the
  # environment, so this one bridge makes the whole AI stack
  # settings-aware without touching it.
  # ameba:disable Metrics/CyclomaticComplexity
  def self.apply_ai_to_env(settings : Settings) : Bool
    @@bridge_mutex.synchronize do
      @@bridged_env_keys.each do |key, written|
        ENV.delete(key) if ENV[key]? == written
      end
      @@bridged_env_keys.clear
      changed = false
      ai = settings.ai
      return false unless ai && ai.set?

      if provider = ai.provider
        unless provider.empty? || ENV["GRAFITO_AI_PROVIDER"]?
          ENV["GRAFITO_AI_PROVIDER"] = provider
          @@bridged_env_keys["GRAFITO_AI_PROVIDER"] = provider
          changed = true
        end
      end
      if api_key = ai.api_key
        unless api_key.empty? || ai_key_set?(provider)
          key_var = ai_key_env(provider)
          ENV[key_var] = api_key
          @@bridged_env_keys[key_var] = api_key
          changed = true
        end
      end
      if model = ai.model
        unless model.empty? || ENV["GRAFITO_AI_MODEL"]?
          ENV["GRAFITO_AI_MODEL"] = model
          @@bridged_env_keys["GRAFITO_AI_MODEL"] = model
          changed = true
        end
      end
      changed
    end
  end

  # The environment variable each provider reads its key from.
  # Anthropic has its own; everything else goes through the generic
  # OpenAI-compatible fallback key.
  private def self.ai_key_env(provider : String?) : String
    provider == "anthropic" ? "ANTHROPIC_API_KEY" : "GRAFITO_AI_API_KEY"
  end

  private def self.ai_key_set?(provider : String?) : Bool
    !ENV[ai_key_env(provider)]?.nil?
  end
end
