# # Settings view
#
# The settings view is grafito's own control panel: basic-auth
# credentials, the display timezone, the AI provider and the homepage
# basics (title, hostname, weather), all stored in the settings store
# (`settings.json` under the data dir) and applied live — no restarts.
#
# It is also the onboarding wizard. On a fresh instance (no
# credentials anywhere, onboarding not done) the same endpoint renders
# as a wizard whose first job is creating the login, and
# `POST /settings/onboard` is the one state-changing endpoint that
# works while unauthenticated. The moment credentials exist the wizard
# is gone and the endpoint closes forever (403), exactly like every
# other mutation, which requires authentication.
#
# Like every other view it is an HTMX fragment; the frontend fetches
# it on demand (no polling) via the VIEWS registry. Boot configuration
# (CLI flags, environment, `GRAFITO_CONFIG`) always wins over the
# settings store: fields owned by the environment render read-only
# notices instead of inputs.

require "html_builder"
require "log"
require "time"

require "./settings_store"
require "./view_helpers"
require "./homepage_config"
require "./ai/config"

module SettingsDashboard
  extend self

  Log = ::Log.for(self)

  # Provider catalog for the AI select. Availability still depends on
  # a key existing (environment or settings); the settings view is how
  # a key gets here in the first place, so the full list is always
  # offered.
  AI_CATALOG = {
    ""          => "Auto-detect from environment",
    "anthropic" => "Anthropic Claude",
    "z_ai"      => "Z.AI",
    "openai"    => "OpenAI",
    "groq"      => "Groq",
    "together"  => "Together.ai",
    "ollama"    => "Ollama (local endpoint)",
    "jimmy"     => "ChatJimmy (free, unofficial)",
  }

  # Timezone suggestions for the datalist; any IANA name validates.
  SUGGESTED_TIMEZONES = [
    "local", "UTC",
    "America/Argentina/Buenos_Aires", "America/Montevideo",
    "America/Santiago", "America/Sao_Paulo", "America/New_York",
    "Europe/London", "Europe/Madrid",
  ]

  # Renders the settings fragment: the wizard on a fresh instance,
  # the sections form otherwise. `errors`/`input` re-render a failed
  # save with its values, `saved` shows the confirmation banner.
  def render_html(
    settings : SettingsStore::Settings,
    auth_env : Bool,
    timezone : String,
    file_config : HomepageConfig::Config?,
    errors : Array(String) = [] of String,
    input : Hash(String, String) = {} of String => String,
    saved : Bool = false,
    demo : Bool = false,
  ) : String
    wizard = !Grafito.auth_configured? && !settings.onboarded?
    HTML.build do
      tag("h2") { text wizard ? "Welcome to grafito" : "Settings" }
      unless errors.empty?
        div(class: "service-panel-error appstore-errors") do
          errors.each do |error|
            tag("p") { text error }
          end
        end
      end
      if saved
        div(class: "inline-alert") do
          text demo ? "Settings saved. (Demo mode: this change is simulated)" : "Settings saved."
        end
      end
      if wizard
        html wizard_fragment(settings, timezone, input)
      else
        html settings_fragment(settings, auth_env: auth_env, timezone: timezone,
          file_config: file_config, input: input)
      end
    end
  end

  # ## The wizard
  #
  # One form, four steps, one button. Only the login is required;
  # everything else can be filled (or left for the settings view
  # later, via the same fields).
  private def wizard_fragment(
    settings : SettingsStore::Settings,
    timezone : String,
    input : Hash(String, String),
  ) : String
    HTML.build do
      div(class: "settings-hint") do
        tag("p") do
          text "This instance has no login yet. Create one to protect your logs and enable actions — it takes effect immediately."
        end
      end
      tag("form", {
        "class"    => "appstore-install-form settings-form",
        "onsubmit" => "return false",
      }) do
        div(class: "settings-section") do
          div(class: "settings-section-title") { text "1 · Create your login" }
          html field("Username", "auth_user", input["auth_user"]?, required: true, autocomplete: "username")
          html field("Password", "auth_pass", "", type: "password", required: true,
            hint: "At least 4 characters", autocomplete: "new-password")
          html field("Repeat password", "auth_pass2", "", type: "password", required: true, autocomplete: "new-password")
        end
        div(class: "settings-section") do
          div(class: "settings-section-title") { text "2 · Timezone (optional)" }
          html timezone_field(timezone)
        end
        div(class: "settings-section") do
          div(class: "settings-section-title") { text "3 · Homepage basics (optional)" }
          html field("Title", "hp_title", input["hp_title"]?)
          html field("Hostname for app links", "hp_hostname", input["hp_hostname"]?,
            hint: "Used for services declared with only a port")
        end
        div(class: "settings-section") do
          div(class: "settings-section-title") { text "4 · AI explanations (optional)" }
          html ai_provider_field(settings, input)
          html field("API key", "ai_key", "", type: "password",
            hint: "Only needed for paid providers; never shown again once saved")
        end
        button(class: "service-panel-explain appstore-install-button", type: "button",
          "hx-post": "#{ViewHelpers.base_prefix}/settings/onboard",
          "hx-include": "closest form",
          "hx-target": "#settings-view",
          "hx-swap": "innerHTML",
          "hx-indicator": "#loading-spinner") do
          text "Save and finish"
        end
      end
    end
  end

  # ## The settings form
  # ameba:disable Metrics/CyclomaticComplexity
  private def settings_fragment(
    settings : SettingsStore::Settings,
    auth_env : Bool,
    timezone : String,
    file_config : HomepageConfig::Config?,
    input : Hash(String, String),
  ) : String
    HTML.build do
      tag("form", {
        "class"    => "appstore-install-form settings-form",
        "onsubmit" => "return false",
      }) do
        div(class: "settings-section") do
          div(class: "settings-section-title") { text "Access" }
          if auth_env
            div(class: "service-panel-hint") do
              text "Credentials come from GRAFITO_AUTH_USER/GRAFITO_AUTH_PASS and are managed by the environment."
            end
          else
            html field("Username", "auth_user", input["auth_user"]? || settings.auth_user.to_s,
              autocomplete: "username")
            html field("New password", "auth_pass", "", type: "password",
              hint: "Leave blank to keep the current one", autocomplete: "new-password")
            html field("Repeat new password", "auth_pass2", "", type: "password", autocomplete: "new-password")
          end
        end
        div(class: "settings-section") do
          div(class: "settings-section-title") { text "Display" }
          html timezone_field(input["timezone"]? || timezone)
        end
        div(class: "settings-section") do
          div(class: "settings-section-title") { text "AI explanations" }
          html ai_provider_field(settings, input)
          html field("API key", "ai_key", "", type: "password",
            hint: "Leave blank to keep the saved one")
          html field("Model", "ai_model", input["ai_model"]? || settings.ai.try(&.model).to_s,
            hint: "Blank uses the provider default")
        end
        div(class: "settings-section") do
          div(class: "settings-section-title") { text "Homepage" }
          tag("p", class: "service-panel-hint") do
            text "These override homepage.yml (which still provides the service groups)."
          end
          html field("Title", "hp_title", input["hp_title"]? || overlay_or_file(settings, file_config, "title"))
          html field("Hostname for app links", "hp_hostname", input["hp_hostname"]? || overlay_or_file(settings, file_config, "hostname"),
            hint: "Used for services declared with only a port")
          html field("Weather latitude", "hp_latitude", input["hp_latitude"]? || weather_value(settings, file_config, "latitude"),
            hint: "Latitude and longitude together switch the weather location")
          html field("Weather longitude", "hp_longitude", input["hp_longitude"]? || weather_value(settings, file_config, "longitude"))
          html field("Weather location name", "hp_location", input["hp_location"]? || weather_value(settings, file_config, "location"))
          html units_select(input["hp_units"]? || weather_value(settings, file_config, "units"))
        end
        button(class: "service-panel-explain appstore-install-button", type: "button",
          "hx-post": "#{ViewHelpers.base_prefix}/settings/save",
          "hx-include": "closest form",
          "hx-target": "#settings-view",
          "hx-swap": "innerHTML",
          "hx-indicator": "#loading-spinner") do
          text "Save settings"
        end
      end
      div(class: "settings-hint") do
        tag("p") do
          text "Stored in #{HTML.escape(SettingsStore.path(Grafito.data_dir))}. Boot configuration (flags, environment, GRAFITO_CONFIG) always takes precedence."
        end
      end
    end
  end

  # ## Field helpers

  # One labeled input. Passwords are never echoed back.
  private def field(label_text : String, name : String, value : String? = nil,
                    type : String = "text", required : Bool = false,
                    hint : String = "", autocomplete : String = "") : String
    HTML.build do
      div(class: "appstore-field") do
        label(for: "settings-#{name}") { text label_text }
        attrs = {"id" => "settings-#{name}", "name" => name, "type" => type}
        attrs["autocomplete"] = autocomplete unless autocomplete.empty?
        attrs["value"] = value if value && type != "password"
        attrs["required"] = "required" if required
        input(attrs)
        tag("small", class: "settings-field-hint") { text hint } unless hint.empty?
      end
    end
  end

  private def timezone_field(value : String) : String
    HTML.build do
      div(class: "appstore-field") do
        label(for: "settings-timezone") { text "Timezone" }
        input({
          "id"    => "settings-timezone",
          "name"  => "timezone",
          "type"  => "text",
          "value" => value,
          "list"  => "settings-timezones",
        })
        tag("datalist", {"id" => "settings-timezones"}) do
          SUGGESTED_TIMEZONES.each do |zone|
            tag("option", {"value" => zone}) { }
          end
        end
        tag("small", class: "settings-field-hint") { text "IANA name, or local / UTC" }
      end
    end
  end

  private def ai_provider_field(settings : SettingsStore::Settings, input : Hash(String, String)) : String
    current = input["ai_provider"]? || settings.ai.try(&.provider).to_s
    HTML.build do
      div(class: "appstore-field") do
        label(for: "settings-ai-provider") { text "Provider" }
        tag("select", {"id" => "settings-ai-provider", "name" => "ai_provider"}) do
          AI_CATALOG.each do |id, name|
            selected = id == current ? {"selected" => "selected"} : Hash(String, String).new
            tag("option", {"value" => id}.merge(selected)) { text name }
          end
        end
      end
    end
  end

  private def units_select(value : String) : String
    HTML.build do
      div(class: "appstore-field") do
        label(for: "settings-hp-units") { text "Weather units" }
        tag("select", {"id" => "settings-hp-units", "name" => "hp_units"}) do
          {"metric" => "Metric (°C, km/h)", "imperial" => "Imperial (°F, mph)"}.each do |units, name|
            selected = units == value ? {"selected" => "selected"} : Hash(String, String).new
            tag("option", {"value" => units}.merge(selected)) { text name }
          end
        end
      end
    end
  end

  # The value shown for a homepage basic: the settings overlay's when
  # set, otherwise the file's, otherwise empty.
  private def overlay_or_file(settings : SettingsStore::Settings,
                              file_config : HomepageConfig::Config?, key : String) : String
    overlay = settings.homepage
    case key
    when "title"
      (overlay.try(&.title) || file_config.try(&.title)).to_s
    when "hostname"
      (overlay.try(&.hostname) || file_config.try(&.hostname)).to_s
    else
      ""
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity
  private def weather_value(settings : SettingsStore::Settings,
                            file_config : HomepageConfig::Config?, key : String) : String
    overlay = settings.homepage.try(&.weather)
    file_weather = file_config.try(&.weather)
    case key
    when "latitude"
      value = overlay.try(&.latitude) || file_weather.try(&.latitude)
      value.nil? ? "" : value.to_s
    when "longitude"
      value = overlay.try(&.longitude) || file_weather.try(&.longitude)
      value.nil? ? "" : value.to_s
    when "location"
      (overlay.try(&.location) || file_weather.try(&.location)).to_s
    when "units"
      (overlay.try(&.units) || file_weather.try(&.units) || "metric").to_s
    else
      ""
    end
  end

  # ## Routes

  private def self.route_path(path : String) : String
    Grafito.route_path(path)
  end

  def self.register_routes
    get route_path("settings") do |env|
      unless Grafito.settings_enabled?
        env.response.status_code = 404
        next "Settings view is disabled."
      end
      env.response.content_type = "text/html"
      render_fragment
    end

    post route_path("settings/save") do |env|
      unless Grafito.settings_enabled?
        env.response.status_code = 404
        next "Settings view is disabled."
      end
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403
      end
      # On an unauthenticated instance this endpoint stays closed:
      # credentials enter through the onboarding wizard instead.
      # Demo builds allow it: the change is simulated, like every
      # other action there.
      unless Grafito.auth_configured? || Grafito.demo_mode?
        env.response.status_code = 403
        next "Settings changes require authentication."
      end
      save_settings(env, onboarding: false)
    end

    # The one endpoint that answers while unauthenticated, and only
    # while that is still true: it exists to create the first login.
    # Once credentials exist (environment or settings) or onboarding
    # completed, it refuses forever.
    post route_path("settings/onboard") do |env|
      unless Grafito.settings_enabled?
        env.response.status_code = 404
        next "Settings view is disabled."
      end
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403
      end
      if Grafito.auth_configured? || SettingsStore.load(Grafito.data_dir).onboarded?
        env.response.status_code = 403
        next "Onboarding is already complete."
      end
      save_settings(env, onboarding: true)
    end
  end

  # Loads everything the fragment needs and renders it.
  private def self.render_fragment(errors : Array(String) = [] of String,
                                   input : Hash(String, String) = {} of String => String,
                                   saved : Bool = false) : String
    settings = SettingsStore.load(Grafito.data_dir)
    file_config = begin
      path = Grafito.homepage_config_path
      HomepageConfig::Config.load(path) if File.exists?(path)
    rescue ex
      Log.warn { "Homepage config unreadable for settings display: #{ex.message}" }
      nil
    end
    render_html(settings,
      auth_env: SettingsStore.auth_from_env?,
      timezone: Grafito.timezone,
      file_config: file_config,
      errors: errors, input: input, saved: saved,
      demo: Grafito.demo_mode?)
  end

  # Validates the submitted form, persists the merged settings and
  # applies them live. Re-renders with errors (and the submitted
  # non-secret values) when something does not validate.
  private def self.save_settings(env, onboarding : Bool) : String
    settings = SettingsStore.load(Grafito.data_dir)
    errors = [] of String
    input = {} of String => String

    auth_user = body_param(env, "auth_user")
    auth_pass = body_param(env, "auth_pass")
    auth_pass_confirm = body_param(env, "auth_pass2")
    timezone_param = body_param(env, "timezone")
    ai_provider = body_param(env, "ai_provider")
    ai_key = body_param(env, "ai_key")
    ai_model = body_param(env, "ai_model")
    homepage_title = body_param(env, "hp_title")
    homepage_hostname = body_param(env, "hp_hostname")
    weather_latitude = body_param(env, "hp_latitude")
    weather_longitude = body_param(env, "hp_longitude")
    weather_location = body_param(env, "hp_location")
    weather_units = body_param(env, "hp_units")

    # Echo non-secret fields back on error.
    {"auth_user" => auth_user, "timezone" => timezone_param,
     "ai_provider" => ai_provider, "ai_model" => ai_model,
     "hp_title" => homepage_title, "hp_hostname" => homepage_hostname,
     "hp_latitude" => weather_latitude, "hp_longitude" => weather_longitude,
     "hp_location" => weather_location}.each do |name, value|
      input[name] = value
    end

    # --- Access ---
    if onboarding
      errors << "Choose a username." if auth_user.empty?
      errors << "Password must be at least 4 characters." if auth_pass.size < 4
      errors << "Passwords do not match." if auth_pass != auth_pass_confirm
      if errors.empty?
        settings.auth_user = auth_user
        settings.auth_pass = auth_pass
      end
    elsif !SettingsStore.auth_from_env?
      if auth_pass.empty?
        settings.auth_user = auth_user unless auth_user.empty?
      else
        errors << "New passwords do not match." if auth_pass != auth_pass_confirm
        errors << "Password must be at least 4 characters." if auth_pass.size < 4
        unless errors.any? { |error| error.starts_with?("Password") || error.starts_with?("New passwords") }
          settings.auth_user = auth_user unless auth_user.empty?
          settings.auth_pass = auth_pass
        end
      end
    end

    # --- Timezone ---
    unless timezone_param.empty?
      if valid_timezone?(timezone_param)
        settings.timezone = timezone_param
      else
        errors << "Unknown timezone '#{timezone_param}'."
      end
    end

    # --- AI ---
    if ai_provider.empty?
      settings.ai = nil
    elsif !AI_CATALOG.has_key?(ai_provider)
      errors << "Unknown AI provider '#{ai_provider}'."
    else
      existing = settings.ai
      settings.ai = SettingsStore::AISettings.new(
        provider: ai_provider,
        api_key: ai_key.empty? ? existing.try(&.api_key) : ai_key,
        model: ai_model.empty? ? nil : ai_model,
      )
    end

    # --- Homepage overlay ---
    # The form always submits every field, so the posted values are
    # the whole truth: an empty field clears that override and lets
    # homepage.yml (or the defaults) provide it again.
    existing_homepage = settings.homepage
    overlay_title = homepage_title.empty? ? existing_homepage.try(&.title) : homepage_title
    overlay_hostname = homepage_hostname.empty? ? existing_homepage.try(&.hostname) : homepage_hostname
    overlay_weather = existing_homepage.try(&.weather)
    if weather_latitude.empty? && weather_longitude.empty?
      overlay_weather = nil
    else
      latitude = parse_number(weather_latitude, "latitude", errors)
      longitude = parse_number(weather_longitude, "longitude", errors)
      if latitude && longitude
        overlay_weather = SettingsStore::WeatherSettings.new(
          latitude: latitude, longitude: longitude,
          location: weather_location.empty? ? nil : weather_location,
          units: weather_units.empty? ? nil : weather_units,
        )
      elsif weather_latitude.empty? || weather_longitude.empty?
        errors << "Weather needs both latitude and longitude."
      end
    end
    if overlay_title || overlay_hostname || overlay_weather
      settings.homepage = SettingsStore::HomepageSettings.new(
        title: overlay_title, hostname: overlay_hostname, weather: overlay_weather)
    else
      settings.homepage = nil
    end

    env.response.content_type = "text/html"
    if errors.empty?
      settings.onboarded = true if onboarding
      apply_live(settings)
      {% if flag?(:demo_mode) %}
        FakeSettings.save(settings)
        Log.info { "Demo: settings change simulated" }
        return render_fragment(saved: true)
      {% else %}
        SettingsStore.save(Grafito.data_dir, settings)
        Log.info { "Settings saved#{onboarding ? " (onboarding complete)" : ""}" }
      {% end %}
      if onboarding
        onboarding_complete_fragment(settings)
      else
        render_fragment(saved: true)
      end
    else
      render_fragment(errors: errors, input: input)
    end
  end

  # What the browser sees right after onboarding: the next request
  # will ask for the new credentials, so say so instead of leaving a
  # silently-401ing page behind.
  private def self.onboarding_complete_fragment(settings : SettingsStore::Settings) : String
    HTML.build do
      div(class: "settings-hint") do
        tag("h2") { text "Onboarding complete" }
        tag("p") do
          text "Login created for '#{HTML.escape(settings.auth_user.to_s)}'. Reload the page and sign in with your new credentials — actions are unlocked from now on."
        end
      end
    end
  end

  # Applies what the settings own: the timezone immediately, and the
  # AI provider rebuilt after its configuration is bridged into the
  # environment the providers read. Credentials need no application:
  # the auth handler resolves them per request.
  private def self.apply_live(settings : SettingsStore::Settings) : Nil
    if timezone = settings.timezone
      Grafito.timezone = timezone
    end
    SettingsStore.apply_ai_to_env(settings)
    Grafito.ai_provider = Grafito::AI::Config.provider
  end

  private def self.valid_timezone?(name : String) : Bool
    return true if {"local", "utc", "etc/utc"}.includes?(name.downcase)
    Time::Location.load(name)
    true
  rescue ex
    Log.debug { "Timezone '#{name}' rejected: #{ex.message}" }
    false
  end

  private def self.parse_number(value : String, what : String, errors : Array(String)) : Float64?
    return if value.empty?
    number = value.to_f64?
    errors << "Weather #{what} must be a number." unless number
    number
  end

  private def self.body_param(env, key : String) : String
    env.params.body[key]? || Grafito.optional_query_param(env, key) || ""
  end
end
