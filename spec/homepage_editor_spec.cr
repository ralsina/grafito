require "./spec_helper"

# Homepage YAML editor specs: the editor fragment's starting point,
# the review diff, the apply write (rolling backup + overlay
# retirement), validation and the gates. The atomic write itself is
# compose_dashboard's apply_stack_file (covered in compose_spec);
# these specs cover the homepage behavior around it.

EDITOR_FORM_HEADERS = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}

# Form posts that claim to come from another site (the CSRF signal
# modern browsers always send along).
CROSS_SITE_HEADERS = HTTP::Headers{
  "Content-Type"   => "application/x-www-form-urlencoded",
  "Sec-Fetch-Site" => "cross-site",
}

# A config with a marker comment, so specs can tell raw file text
# from serialized config apart.
RAW_CONFIG = <<-YAML
  # managed by hand
  title: Lab
  hostname: lab-host
  groups:
    - name: Media
      services:
        - name: Jellyfin
          port: 8096
          description: Movies
  YAML

# Points the app at a throwaway data dir + config file, and turns the
# actions gate on or off (the editor needs actions, like the compose
# file editor).
def with_homepage_editor_env(file_text : String?, actions : Bool = true, &)
  data_dir = File.tempname("grafito-homepage-editor", "")
  Dir.mkdir(data_dir)
  config_path = File.join(data_dir, "homepage.yml")
  File.write(config_path, file_text) if file_text

  old_data_dir = Grafito.data_dir
  old_config = Grafito.homepage_config_path
  old_actions = Grafito.enable_actions?
  old_override = Grafito.auth_configured_override
  begin
    Grafito.data_dir = data_dir
    Grafito.homepage_config_path = config_path
    Grafito.enable_actions = actions
    Grafito.auth_configured_override = actions
    yield data_dir, config_path
  ensure
    Grafito.data_dir = old_data_dir
    Grafito.homepage_config_path = old_config
    Grafito.enable_actions = old_actions
    Grafito.auth_configured_override = old_override
    FileUtils.rm_rf(data_dir)
  end
end

# Saves a settings.json carrying a homepage overlay into data_dir.
def write_overlay(data_dir : String, title : String)
  settings = SettingsStore::Settings.new
  settings.homepage = SettingsStore::HomepageSettings.new(title: title)
  SettingsStore.save(data_dir, settings)
end

describe "Homepage config editor" do
  # Serialization must survive a load → to_yaml → load round trip,
  # including the port form (port kept, url already resolved).
  it "round-trips the example config through to_yaml" do
    config = HomepageConfig::Config.from_yaml(HomepageDashboard::EXAMPLE_CONFIG)
    reloaded = HomepageConfig::Config.from_yaml(config.to_yaml)

    reloaded.title.should eq(config.title)
    reloaded.hostname.should eq(config.hostname)
    reloaded.groups.map(&.name).should eq(config.groups.map(&.name))
    reloaded.groups.flat_map(&.services).map(&.url).should eq(
      config.groups.flat_map(&.services).map(&.url))

    jellyfin = reloaded.groups.flat_map(&.services).find(&.name.==("Jellyfin"))
    jellyfin.try(&.port).should eq(8096)
  end

  {% unless flag?(:demo_mode) %}
    describe "GET /homepage-edit" do
      it "serves the raw file (comments included) when there is no overlay" do
        with_homepage_editor_env(RAW_CONFIG) do |_data_dir, _config_path|
          response = dispatch_request("GET", "/homepage-edit")
          response[:status].should eq(200)
          response[:body].should contain("# managed by hand")
          response[:body].should contain("Review changes")
        end
      end

      it "bakes the settings overlay into the starting point" do
        with_homepage_editor_env(RAW_CONFIG) do |data_dir, _config_path|
          write_overlay(data_dir, "Overlay Title")
          response = dispatch_request("GET", "/homepage-edit")
          response[:status].should eq(200)
          response[:body].should contain("Overlay Title")
          # The overlay value replaces the file's raw one in the draft.
          response[:body].should_not contain("title: Lab")
        end
      end

      it "prefills the example config when the file is missing" do
        with_homepage_editor_env(nil) do |_data_dir, _config_path|
          response = dispatch_request("GET", "/homepage-edit")
          response[:status].should eq(200)
          response[:body].should contain("title: Homelab")
        end
      end

      it "offers a broken file raw so it can be repaired" do
        with_homepage_editor_env("groups: [unclosed") do |_data_dir, _config_path|
          response = dispatch_request("GET", "/homepage-edit")
          response[:status].should eq(200)
          response[:body].should contain("groups: [unclosed")
        end
      end

      it "is closed without actions" do
        with_homepage_editor_env(RAW_CONFIG, actions: false) do |_data_dir, _config_path|
          dispatch_request("GET", "/homepage-edit")[:status].should eq(403)
        end
      end
    end

    describe "POST /homepage-edit-diff" do
      it "reviews without writing" do
        with_homepage_editor_env(RAW_CONFIG) do |_data_dir, config_path|
          draft = RAW_CONFIG.gsub("title: Lab", "title: Lab 2")
          response = dispatch_request("POST", "/homepage-edit-diff",
            body: "content=#{URI.encode_www_form(draft)}", headers: EDITOR_FORM_HEADERS)

          response[:status].should eq(200)
          response[:body].should contain("Review changes")
          response[:body].should contain("+title: Lab 2")
          File.read(config_path).should eq(RAW_CONFIG)
        end
      end

      it "rejects a draft that does not parse" do
        with_homepage_editor_env(RAW_CONFIG) do |_data_dir, config_path|
          response = dispatch_request("POST", "/homepage-edit-diff",
            body: "content=groups:+[unclosed", headers: EDITOR_FORM_HEADERS)

          response[:status].should eq(200)
          response[:body].should contain("YAML:")
          File.read(config_path).should eq(RAW_CONFIG)
        end
      end

      it "rejects a port service without a hostname" do
        with_homepage_editor_env(RAW_CONFIG) do |_data_dir, config_path|
          draft = "groups:\n- name: G\n  services:\n  - name: S\n    port: 1234\n"
          response = dispatch_request("POST", "/homepage-edit-diff",
            body: "content=#{URI.encode_www_form(draft)}", headers: EDITOR_FORM_HEADERS)

          response[:status].should eq(200)
          response[:body].should contain("no hostname")
          File.read(config_path).should eq(RAW_CONFIG)
        end
      end

      it "rejects cross-site posts" do
        with_homepage_editor_env(RAW_CONFIG) do |_data_dir, _config_path|
          response = dispatch_request("POST", "/homepage-edit-diff",
            body: "content=x", headers: CROSS_SITE_HEADERS)
          response[:status].should eq(403)
        end
      end
    end

    describe "POST /homepage-edit-apply" do
      it "writes the draft, backs the file up and retires the overlay" do
        with_homepage_editor_env(RAW_CONFIG) do |data_dir, config_path|
          write_overlay(data_dir, "Overlay Title")
          draft = HomepageDashboard.effective_config.to_yaml
          draft = draft.gsub("title: Overlay Title", "title: Edited")

          response = dispatch_request("POST", "/homepage-edit-apply",
            body: "content=#{URI.encode_www_form(draft)}", headers: EDITOR_FORM_HEADERS)

          response[:status].should eq(200)
          response[:body].should contain("Homepage written")
          # The written page refreshes behind the panel.
          response[:body].should contain(%(hx-get="/homepage"))
          File.read(config_path).should contain("title: Edited")
          # The old contents survive next to it, and the overlay is gone.
          File.read(config_path + ".grafito-bak").should eq(RAW_CONFIG)
          SettingsStore.load(data_dir).homepage.should be_nil
        end
      end

      it "keeps the draft editable when the file is not writable" do
        # chmod does not stop root, so the whole scenario is vacuous
        # when specs run as root (e.g. in the builder container).
        unless LibC.getuid == 0
          with_homepage_editor_env(RAW_CONFIG) do |_data_dir, config_path|
            File.chmod(File.dirname(config_path), 0o500)
            begin
              draft = RAW_CONFIG.gsub("title: Lab", "title: Lab 2")
              response = dispatch_request("POST", "/homepage-edit-apply",
                body: "content=#{URI.encode_www_form(draft)}", headers: EDITOR_FORM_HEADERS)

              response[:status].should eq(200)
              response[:body].should contain("not writable")
              response[:body].should contain("title: Lab 2")
              File.read(config_path).should eq(RAW_CONFIG)
            ensure
              File.chmod(File.dirname(config_path), 0o700)
            end
          end
        end
      end

      it "validates before writing" do
        with_homepage_editor_env(RAW_CONFIG) do |_data_dir, config_path|
          response = dispatch_request("POST", "/homepage-edit-apply",
            body: "content=groups:+[unclosed", headers: EDITOR_FORM_HEADERS)

          response[:status].should eq(200)
          response[:body].should contain("YAML:")
          File.read(config_path).should eq(RAW_CONFIG)
        end
      end

      it "is closed without actions or cross-site" do
        with_homepage_editor_env(RAW_CONFIG, actions: false) do |_data_dir, _config_path|
          dispatch_request("POST", "/homepage-edit-apply",
            body: "content=x", headers: EDITOR_FORM_HEADERS)[:status].should eq(403)
        end
        with_homepage_editor_env(RAW_CONFIG) do |_data_dir, _config_path|
          dispatch_request("POST", "/homepage-edit-apply",
            body: "content=x", headers: CROSS_SITE_HEADERS)[:status].should eq(403)
        end
      end
    end

    describe "the Edit button on the view" do
      it "appears with actions and opens the editor" do
        with_homepage_editor_env(RAW_CONFIG) do |_data_dir, _config_path|
          response = dispatch_request("GET", "/homepage")
          response[:body].should contain("/homepage-edit")
        end
      end

      it "stays hidden without actions" do
        with_homepage_editor_env(RAW_CONFIG, actions: false) do |_data_dir, _config_path|
          response = dispatch_request("GET", "/homepage")
          response[:body].should_not contain("/homepage-edit")
        end
      end

      it "the setup hint offers the editor for a missing config" do
        with_homepage_editor_env(nil) do |_data_dir, _config_path|
          response = dispatch_request("GET", "/homepage")
          response[:body].should contain("Open the editor")
        end
      end
    end
  {% end %}

  {% if flag?(:demo_mode) %}
    it "GET serves the fake config and apply simulates the write" do
      Grafito.enable_actions = false
      Grafito.auth_configured_override = false
      config_path = Grafito.homepage_config_path
      begin
        editor = dispatch_request("GET", "/homepage-edit")
        editor[:status].should eq(200)
        editor[:body].should contain("Gitea")

        draft = FakeHomepageData.config.to_yaml
        applied = dispatch_request("POST", "/homepage-edit-apply",
          body: "content=#{URI.encode_www_form(draft)}", headers: EDITOR_FORM_HEADERS)
        applied[:status].should eq(200)
        applied[:body].should contain("Homepage written")
        File.exists?(config_path).should be_false
      ensure
        Grafito.enable_actions = true
        Grafito.auth_configured_override = nil
      end
    end
  {% end %}
end
