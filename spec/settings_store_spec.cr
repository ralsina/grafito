require "./spec_helper"

# Settings store specs: persistence shape, precedence over (and
# bridging into) the environment, and the graceful-degradation paths.
# Runs the block with the given env keys set (value) or removed
# (nil), restoring whatever was there before.
def with_env(pairs : Hash(String, String?), &)
  saved = {} of String => String?
  pairs.each do |key, value|
    saved[key] = ENV[key]?
    if value
      ENV[key] = value
    else
      ENV.delete(key)
    end
  end
  yield
ensure
  if saved
    saved.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end
end

describe SettingsStore do
  {% unless flag?(:demo_mode) %}
    # These touch the real settings file; demo builds keep the store
    # in memory.
    it "returns defaults when no settings file exists" do
      data_dir = File.tempname("grafito-settings", "")
      Dir.mkdir(data_dir)
      begin
        settings = SettingsStore.load(data_dir)
        settings.auth_user.should be_nil
        settings.onboarded?.should be_false
        settings.ai.should be_nil
        settings.homepage.should be_nil
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "saves and reloads every section with 0600 permissions" do
      data_dir = File.tempname("grafito-settings", "")
      Dir.mkdir(data_dir)
      begin
        settings = SettingsStore::Settings.new(
          auth_user: "admin",
          auth_pass: "secret",
          timezone: "UTC",
          onboarded: true,
          ai: SettingsStore::AISettings.new(provider: "z_ai", api_key: "k", model: "m"),
          homepage: SettingsStore::HomepageSettings.new(
            title: "Lab",
            hostname: "rocky",
            weather: SettingsStore::WeatherSettings.new(
              latitude: -34.6, longitude: -58.38, location: "Buenos Aires")))
        SettingsStore.save(data_dir, settings)

        settings_path = SettingsStore.path(data_dir)
        File.info(settings_path).permissions.to_s.should contain("0o600")
        reloaded = SettingsStore.load(data_dir)
        reloaded.auth_user.should eq("admin")
        reloaded.auth_pass.should eq("secret")
        reloaded.timezone.should eq("UTC")
        reloaded.onboarded?.should be_true
        ai = reloaded.ai
        if ai
          ai.provider.should eq("z_ai")
          ai.api_key.should eq("k")
          ai.model.should eq("m")
        else
          fail("ai settings should have been reloaded")
        end
        homepage = reloaded.homepage
        if homepage
          homepage.title.should eq("Lab")
          homepage.hostname.should eq("rocky")
          weather = homepage.weather
          if weather
            weather.latitude.should eq(-34.6)
            weather.longitude.should eq(-58.38)
            weather.location.should eq("Buenos Aires")
          else
            fail("weather settings should have been reloaded")
          end
        else
          fail("homepage settings should have been reloaded")
        end
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end

    it "falls back to defaults on an unreadable settings file" do
      data_dir = File.tempname("grafito-settings", "")
      Dir.mkdir(data_dir)
      begin
        File.write(SettingsStore.path(data_dir), "{not json")
        settings = SettingsStore.load(data_dir)
        settings.auth_user.should be_nil
        settings.onboarded?.should be_false
      ensure
        FileUtils.rm_rf(data_dir)
      end
    end
  {% end %}

  describe ".env_auth" do
    it "yields the pair when both variables are set" do
      with_env({"GRAFITO_AUTH_USER" => "u", "GRAFITO_AUTH_PASS" => "p"}) do
        credentials = SettingsStore.env_auth
        if credentials
          credentials[0].should eq("u")
          credentials[1].should eq("p")
        else
          fail("env_auth should have yielded credentials")
        end
      end
    end

    it "yields nil when only one is set" do
      with_env({"GRAFITO_AUTH_USER" => "u", "GRAFITO_AUTH_PASS" => nil}) do
        SettingsStore.env_auth.should be_nil
      end
    end
  end

  {% unless flag?(:demo_mode) %}
    # Effective-auth specs write and read the real store.
    describe ".effective_auth" do
      it "prefers the environment over the settings file" do
        data_dir = File.tempname("grafito-settings", "")
        Dir.mkdir(data_dir)
        begin
          SettingsStore.save(data_dir, SettingsStore::Settings.new(auth_user: "file-user", auth_pass: "file-pass"))
          with_env({"GRAFITO_AUTH_USER" => "env-user", "GRAFITO_AUTH_PASS" => "env-pass"}) do
            credentials = SettingsStore.effective_auth(data_dir)
            if credentials
              credentials[0].should eq("env-user")
            else
              fail("effective_auth should have yielded credentials")
            end
          end
        ensure
          FileUtils.rm_rf(data_dir)
        end
      end

      it "uses the settings file when the environment has nothing" do
        data_dir = File.tempname("grafito-settings", "")
        Dir.mkdir(data_dir)
        begin
          SettingsStore.save(data_dir, SettingsStore::Settings.new(auth_user: "file-user", auth_pass: "file-pass"))
          with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
            credentials = SettingsStore.effective_auth(data_dir)
            if credentials
              credentials[0].should eq("file-user")
              credentials[1].should eq("file-pass")
            else
              fail("effective_auth should have yielded credentials")
            end
          end
        ensure
          FileUtils.rm_rf(data_dir)
        end
      end

      it "yields nil when nothing is configured" do
        data_dir = File.tempname("grafito-settings", "")
        Dir.mkdir(data_dir)
        begin
          with_env({"GRAFITO_AUTH_USER" => nil, "GRAFITO_AUTH_PASS" => nil}) do
            SettingsStore.effective_auth(data_dir).should be_nil
          end
        ensure
          FileUtils.rm_rf(data_dir)
        end
      end
    end
  {% end %}
  describe ".apply_ai_to_env" do
    ai_keys = {"GRAFITO_AI_PROVIDER", "GRAFITO_AI_API_KEY", "ANTHROPIC_API_KEY", "GRAFITO_AI_MODEL"}

    it "bridges provider, key and model into the environment" do
      with_env(ai_keys.to_h { |key| {key, nil} }) do
        # Retract anything a previous spec bridged so the environment
        # starts clean despite specs sharing one process.
        SettingsStore.apply_ai_to_env(SettingsStore::Settings.new)
        settings = SettingsStore::Settings.new(
          ai: SettingsStore::AISettings.new(provider: "z_ai", api_key: "k", model: "m"))
        changed = SettingsStore.apply_ai_to_env(settings)
        changed.should be_true
        ENV["GRAFITO_AI_PROVIDER"].should eq("z_ai")
        ENV["GRAFITO_AI_API_KEY"].should eq("k")
        ENV["GRAFITO_AI_MODEL"].should eq("m")
      end
    end

    it "maps the anthropic provider to its own key variable" do
      with_env(ai_keys.to_h { |key| {key, nil} }) do
        SettingsStore.apply_ai_to_env(SettingsStore::Settings.new)
        settings = SettingsStore::Settings.new(
          ai: SettingsStore::AISettings.new(provider: "anthropic", api_key: "sk"))
        SettingsStore.apply_ai_to_env(settings)
        ENV["ANTHROPIC_API_KEY"].should eq("sk")
        ENV["GRAFITO_AI_API_KEY"]?.should be_nil
      end
    end

    it "never overwrites values the operator set at boot" do
      with_env({"GRAFITO_AI_PROVIDER" => "jimmy", "GRAFITO_AI_MODEL" => nil,
                "GRAFITO_AI_API_KEY" => nil, "ANTHROPIC_API_KEY" => nil}) do
        SettingsStore.apply_ai_to_env(SettingsStore::Settings.new)
        settings = SettingsStore::Settings.new(
          ai: SettingsStore::AISettings.new(provider: "z_ai", api_key: "k", model: "m"))
        SettingsStore.apply_ai_to_env(settings)
        ENV["GRAFITO_AI_PROVIDER"].should eq("jimmy")
      end
    end

    it "retracts keys it bridged when the settings stop providing them" do
      with_env(ai_keys.to_h { |key| {key, nil} }) do
        SettingsStore.apply_ai_to_env(SettingsStore::Settings.new)
        with_ai = SettingsStore::Settings.new(
          ai: SettingsStore::AISettings.new(provider: "z_ai", api_key: "k", model: "m"))
        SettingsStore.apply_ai_to_env(with_ai)
        ENV["GRAFITO_AI_API_KEY"]?.should eq("k")

        without_ai = SettingsStore::Settings.new
        SettingsStore.apply_ai_to_env(without_ai)
        ENV["GRAFITO_AI_PROVIDER"]?.should be_nil
        ENV["GRAFITO_AI_API_KEY"]?.should be_nil
        ENV["GRAFITO_AI_MODEL"]?.should be_nil
      end
    end
  end
end
