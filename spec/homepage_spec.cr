require "./spec_helper"

# A minimal valid config object; specs tweak it via YAML below.
def render_config(yaml : String, weather : Weather::Snapshot? = nil, statuses = {} of String => HomepageDashboard::ReachResult, metrics : Grafito::MetricsStore::MetricPoint? = nil) : String
  config = HomepageConfig::Config.from_yaml(yaml)
  HomepageDashboard.render_html(config, weather, statuses, metrics: metrics)
end

SAMPLE_YAML = <<-YAML
  title: Lab
  groups:
    - name: Media
      services:
        - name: Jellyfin
          url: https://jellyfin.example.com
          description: Movies
          icon: play_circle
          check: true
        - name: Files
          check: true
          url: https://files.example.com
          icon: "🍿"
    - name: Utils
      services:
        - name: Gitea
          url: https://git.example.com
          icon: https://example.com/gitea.svg
        - name: Plain
          url: https://plain.example.com
  YAML

# Homepage view specs: pure rendering (no network), the /homepage
# route's degradation ladder, and the opt-in reachability probes.
describe HomepageDashboard do
  describe ".render_html" do
    it "renders the title, groups and service links" do
      html = render_config(SAMPLE_YAML)

      html.should contain("<h2>Lab</h2>")
      html.should contain("homepage-group-title")
      html.should contain("Media")
      html.should contain("Utils")
      html.should contain("homepage-service-name")
      html.should contain("Jellyfin")
      html.should contain("https://jellyfin.example.com")
      html.should contain("Movies")
      html.should contain("rel=\"noopener noreferrer\"")
    end

    it "renders the machine stats strip when the sampler has data" do
      metrics = Grafito::MetricsStore::MetricPoint.new(
        ts: Time.utc,
        load1: 0.42,
        mem_used_pct: 37.5,
        disk_used_pct: 61.0,
        units_total: 10,
        units_failed: 0,
        swap_used_pct: 12.0,
        net_rx_bps: 1536.0,
        net_tx_bps: 204.8,
      )
      html = render_config(SAMPLE_YAML, metrics: metrics)

      html.should contain("homepage-stats")
      html.should contain("Load (1m)")
      html.should contain(">0.42</span>")
      html.should contain(">37.5%</span>")
      html.should contain(">61.0%</span>")
      html.should contain(">12.0%</span>")
      html.should contain("1.5 KiB/s")
      html.should contain("dashboard") # links into the charts
    end

    it "omits the machine stats strip without sampler data" do
      render_config(SAMPLE_YAML).should_not contain("homepage-stats")
    end

    it "renders material, emoji and image icons" do
      html = render_config(SAMPLE_YAML)

      html.should contain(">play_circle</span>")
      html.should contain("homepage-emoji")
      html.should contain("<img src=\"https://example.com/gitea.svg\"")
      # Unset icons fall back to the generic apps glyph.
      html.should contain(">apps</span>")
    end

    it "renders up and down dots for checked services" do
      statuses = {
        "https://jellyfin.example.com" => HomepageDashboard::ReachResult.new(up: true, latency_ms: 24),
        "https://files.example.com"    => HomepageDashboard::ReachResult.new(up: false, latency_ms: nil),
      }
      html = render_config(SAMPLE_YAML, statuses: statuses)

      html.should contain("homepage-dot-up")
      html.should contain("homepage-dot-down")
    end

    it "omits dots for services without a known status" do
      html = render_config(SAMPLE_YAML, statuses: {} of String => HomepageDashboard::ReachResult)

      html.should_not contain("homepage-dot-up")
      html.should_not contain("homepage-dot-down")
    end

    it "renders the weather widget from a snapshot" do
      snapshot = Weather::Snapshot.new(
        temperature: 18.4,
        apparent: 17.2,
        humidity: 63,
        wind_speed: 11.2,
        code: 2,
        daily_code: 3,
        temp_max: 23.1,
        temp_min: 12.3,
      )
      yaml = SAMPLE_YAML + "\n" + <<-YAML
        weather:
          latitude: -34.9
          longitude: -56.16
          location: Montevideo
        YAML

      html = render_config(yaml, snapshot)

      html.should contain("homepage-weather")
      html.should contain("18.4°C")
      html.should contain("Partly cloudy")
      html.should contain("Feels like 17.2°C")
      html.should contain("Humidity 63%")
      html.should contain("Wind 11 km/h")
      html.should contain("High 23.1°C · Low 12.3°C")
      html.should contain("Montevideo")
    end

    it "converts to imperial units when configured" do
      snapshot = Weather::Snapshot.new(temperature: 18.4, wind_speed: 11.2)
      yaml = SAMPLE_YAML + "\n" + <<-YAML
        weather:
          latitude: -34.9
          longitude: -56.16
          units: imperial
        YAML

      html = render_config(yaml, snapshot)

      html.should contain("65.1°F")
      html.should contain("7 mph")
    end

    it "renders a quiet unavailable state without a snapshot" do
      yaml = SAMPLE_YAML + "\n" + <<-YAML
        weather:
          latitude: -34.9
          longitude: -56.16
        YAML

      html = render_config(yaml, nil)

      html.should contain("Weather unavailable")
    end
  end

  describe ".service_statuses" do
    it "probes services concurrently and reports reachability" do
      WebMock.stub(:get, "http://grafito-up.test/")
        .to_return(body: "hello")
      WebMock.stub(:get, "http://grafito-down.test/")
        .to_return(status: 500)

      services = [
        HomepageConfig::Service.from_yaml("name: Up\nurl: http://grafito-up.test/\ncheck: true"),
        HomepageConfig::Service.from_yaml("name: Down\nurl: http://grafito-down.test/\ncheck: true"),
      ]

      statuses = HomepageDashboard.service_statuses(services)

      statuses["http://grafito-up.test/"].up.should be_true
      statuses["http://grafito-down.test/"].up.should be_false
      # The server answered (500), so a latency was measured.
      statuses["http://grafito-down.test/"].latency_ms.should_not be_nil
    end

    it "skips services that do not opt in" do
      services = [
        HomepageConfig::Service.from_yaml("name: Unchecked\nurl: http://grafito-unchecked.test/"),
      ]

      statuses = HomepageDashboard.service_statuses(services)

      statuses.should be_empty
    end
  end

  describe "setup and error fragments" do
    it "shows setup instructions with the config path" do
      html = HomepageDashboard.setup_hint_fragment("/etc/grafito/homepage.yml")

      html.should contain("/etc/grafito/homepage.yml")
      html.should contain("groups:")
      html.should contain("weather:")
    end

    it "shows the parser message on a broken config" do
      html = HomepageDashboard.error_fragment("/etc/grafito/homepage.yml", "bad line 3")

      html.should contain("Could not read")
      html.should contain("bad line 3")
    end
  end
end

# Route-level behavior of GET /homepage.
describe "GET /homepage" do
  it "returns 404 when the view is disabled" do
    Grafito.homepage_enabled = false
    begin
      response = dispatch_request("GET", "/homepage")
      response[:status].should eq(404)
      response[:body].should contain("Homepage view is disabled.")
    ensure
      Grafito.homepage_enabled = true
    end
  end

  {% unless flag?(:demo_mode) %}
    it "renders setup instructions when the config file is missing" do
      path = "/grafito-spec-does-not-exist/homepage.yml"
      Grafito.homepage_config_path = path
      begin
        response = dispatch_request("GET", "/homepage")
        response[:status].should eq(200)
        response[:body].should contain("homepage.yml")
        response[:body].should contain("groups:")
      ensure
        Grafito.homepage_config_path = "/etc/grafito/homepage.yml"
      end
    end
  {% end %}

  {% unless flag?(:demo_mode) %}
    it "renders configured services" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, <<-YAML)
        title: Route Lab
        groups:
          - name: Media
            services:
              - name: Jellyfin
                url: https://jellyfin.example.com
                description: Movies
        YAML
        Grafito.homepage_config_path = path

        response = dispatch_request("GET", "/homepage")

        response[:status].should eq(200)
        response[:body].should contain("Route Lab")
        response[:body].should contain("Jellyfin")
      ensure
        File.delete(path) if File.exists?(path)
        Grafito.homepage_config_path = "/etc/grafito/homepage.yml"
      end
    end
  {% end %}

  {% unless flag?(:demo_mode) %}
    it "renders setup instructions for an empty config" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, "")
        Grafito.homepage_config_path = path

        response = dispatch_request("GET", "/homepage")

        response[:status].should eq(200)
        response[:body].should contain("groups:")
      ensure
        File.delete(path) if File.exists?(path)
        Grafito.homepage_config_path = "/etc/grafito/homepage.yml"
      end
    end
  {% end %}

  {% unless flag?(:demo_mode) %}
    it "renders the parser message for a broken config" do
      path = File.tempname("grafito-homepage", ".yml")
      begin
        File.write(path, "groups: [unclosed")
        Grafito.homepage_config_path = path

        response = dispatch_request("GET", "/homepage")

        response[:status].should eq(200)
        response[:body].should contain("Could not read")
      ensure
        File.delete(path) if File.exists?(path)
        Grafito.homepage_config_path = "/etc/grafito/homepage.yml"
      end
    end
  {% end %}
end
