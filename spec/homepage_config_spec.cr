require "./spec_helper"

# Config parsing specs for the homepage view. The YAML is intentionally
# small; these pin the defaults and the error cases the route relies on.
describe HomepageConfig::Config do
  describe ".load" do
    it "parses groups, services and weather" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, <<-YAML)
          title: Lab
          weather:
            latitude: -34.9
            longitude: -56.16
            location: Montevideo
            units: imperial
          groups:
            - name: Media
              services:
                - name: Jellyfin
                  url: https://jellyfin.example.com
                  description: Movies
                  icon: play_circle
                  check: true
            - name: Utils
              services:
                - name: HA
                  url: https://ha.example.com
          YAML

        config = HomepageConfig::Config.load(path)

        config.title.should eq("Lab")
        config.groups.size.should eq(2)
        config.groups[0].services.size.should eq(1)

        service = config.groups[0].services[0]
        service.name.should eq("Jellyfin")
        service.url.should eq("https://jellyfin.example.com")
        service.description.should eq("Movies")
        service.icon.should eq("play_circle")
        service.check?.should be_true

        # Unspecified fields fall back to their defaults.
        config.groups[1].services[0].description.should eq("")
        config.groups[1].services[0].icon.should eq("")
        config.groups[1].services[0].check?.should be_false

        weather = config.weather
        if weather
          weather.latitude.should eq(-34.9)
          weather.longitude.should eq(-56.16)
          weather.location.should eq("Montevideo")
          weather.imperial?.should be_true
        else
          fail("weather should have been parsed")
        end
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "builds urls for port-only services from the hostname" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, <<-YAML)
          hostname: rocky
          groups:
            - name: Development
              services:
                - name: Gitea
                  port: 3000
                  check: true
                - name: Snips
                  port: 8091
                - name: Chat
                  url: https://chat.example.com
                  port: 9999
          YAML

        config = HomepageConfig::Config.load(path)

        config.hostname.should eq("rocky")
        services = config.groups[0].services
        services[0].url.should eq("http://rocky:3000")
        services[0].check?.should be_true
        services[1].url.should eq("http://rocky:8091")
        # An explicit url is never rewritten, even when a port is present.
        services[2].url.should eq("https://chat.example.com")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "applies defaults for a minimal config" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, <<-YAML)
          groups:
            - name: Only
              services:
                - name: App
                  url: https://app.example.com
          YAML

        config = HomepageConfig::Config.load(path)

        config.title.should eq("Home")
        config.weather.should be_nil
        config.empty?.should be_false
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "treats an empty file as an empty config" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, "")

        config = HomepageConfig::Config.load(path)

        config.empty?.should be_true
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "raises on a service with neither url nor port" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, <<-YAML)
          groups:
            - name: Broken
              services:
                - name: No URL
          YAML

        error = expect_raises(ArgumentError, "needs a url or a port") do
          HomepageConfig::Config.load(path)
        end
        message = error.message
        fail("error should have had a message") unless message
        message.should contain("No URL")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "raises on a port with no hostname" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, <<-YAML)
          groups:
            - name: Broken
              services:
                - name: Gitea
                  port: 3000
          YAML

        error = expect_raises(ArgumentError, "sets no hostname") do
          HomepageConfig::Config.load(path)
        end
        message = error.message
        fail("error should have had a message") unless message
        message.should contain("Gitea")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "raises on malformed YAML" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, "groups: [unclosed")

        expect_raises(YAML::ParseException) do
          HomepageConfig::Config.load(path)
        end
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end
end
