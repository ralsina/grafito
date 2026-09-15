require "./spec_helper"

# The exact query Weather.api_url builds (webmock matches query strings
# exactly, so the stubs pin the API contract).
def weather_query(latitude : String, longitude : String) : Hash(String, String)
  {
    "latitude"      => latitude,
    "longitude"     => longitude,
    "current"       => "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m",
    "daily"         => "weather_code,temperature_2m_max,temperature_2m_min",
    "forecast_days" => "1",
    "timezone"      => "auto",
  }
end

# Weather client specs. Network calls go through webmock, so these run
# offline; the cache is exercised via distinct coordinate pairs (the
# cache is keyed by coordinates and shared across the whole process).
describe Weather do
  describe ".describe" do
    it "maps WMO codes to labels and Material icons" do
      label, icon = Weather.describe(0)
      label.should eq("Clear sky")
      icon.should eq("wb_sunny")

      label, icon = Weather.describe(3)
      label.should eq("Overcast")
      icon.should eq("wb_cloudy")

      label, icon = Weather.describe(61)
      label.should eq("Rain")
      icon.should eq("opacity")

      label, icon = Weather.describe(75)
      label.should eq("Snow")
      icon.should eq("ac_unit")

      label, icon = Weather.describe(95)
      label.should eq("Thunderstorm")
      icon.should eq("flash_on")

      # Unknown codes get a safe fallback instead of an exception.
      label, icon = Weather.describe(42)
      label.should eq("Unknown")
      icon.should eq("help_outline")
    end
  end

  describe ".snapshot" do
    it "parses an Open-Meteo response" do
      WebMock.stub(:get, "https://api.open-meteo.com/v1/forecast")
        .with(query: weather_query("10.0", "20.0"))
        .to_return(body: <<-JSON
          {
            "current": {
              "time": "2026-09-14T15:00",
              "temperature_2m": 18.4,
              "apparent_temperature": 17.2,
              "relative_humidity_2m": 63,
              "weather_code": 2,
              "wind_speed_10m": 11.2
            },
            "daily": {
              "time": ["2026-09-14"],
              "weather_code": [3],
              "temperature_2m_max": [23.1],
              "temperature_2m_min": [12.3]
            }
          }
          JSON
        )

      snapshot = Weather.snapshot(10.0, 20.0)
      if snapshot
        snapshot.temperature.should eq(18.4)
        snapshot.apparent.should eq(17.2)
        snapshot.humidity.should eq(63)
        snapshot.wind_speed.should eq(11.2)
        snapshot.code.should eq(2)
        snapshot.daily_code.should eq(3)
        snapshot.temp_max.should eq(23.1)
        snapshot.temp_min.should eq(12.3)
      else
        fail("snapshot should have been parsed")
      end
    end

    it "serves repeated reads from the cache" do
      stub = WebMock.stub(:get, "https://api.open-meteo.com/v1/forecast")
        .with(query: weather_query("11.0", "22.0"))
        .to_return(body: %({"current": {"temperature_2m": 21.5, "weather_code": 0}}))

      first = Weather.snapshot(11.0, 22.0)
      second = Weather.snapshot(11.0, 22.0)

      # Both reads return a snapshot but the API was hit only once.
      first.should_not be_nil
      second.should_not be_nil
      stub.calls.should eq(1)
    end

    it "returns nil when the API fails with no cache to fall back on" do
      WebMock.stub(:get, "https://api.open-meteo.com/v1/forecast")
        .with(query: weather_query("12.0", "24.0"))
        .to_return(status: 500)

      Weather.snapshot(12.0, 24.0).should be_nil
    end

    it "falls back to a stale cache entry when a refresh fails" do
      calls = 0
      WebMock.stub(:get, "https://api.open-meteo.com/v1/forecast")
        .with(query: weather_query("13.0", "26.0"))
        .to_return do |_request|
          calls += 1
          if calls == 1
            HTTP::Client::Response.new(200, body: %({"current": {"temperature_2m": 7.7, "weather_code": 71}}))
          else
            HTTP::Client::Response.new(503, body: "")
          end
        end

      good = Weather.snapshot(13.0, 26.0)
      good.should_not be_nil

      stale = Weather.snapshot(13.0, 26.0)
      if stale
        stale.temperature.should eq(7.7)
      else
        fail("stale snapshot should have been served")
      end
    end
  end
end
