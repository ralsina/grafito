# # Weather
#
# The homepage view shows a small weather widget. Instead of growing a
# weather provider abstraction (or an API key requirement), it uses
# [Open-Meteo](https://open-meteo.com): free, keyless and accurate
# enough for a homepage widget.
#
# The module fetches current conditions plus today's forecast for one
# coordinate pair, caches the result in memory for half an hour, and
# degrades gracefully: any failure yields `nil`, which the widget
# renders as "weather unavailable" instead of breaking the page.
# Snapshots always carry metric units; converting to imperial is done
# at render time so the cache does not depend on user settings.

require "http/client"
require "json"
require "log"
require "mutex"

module Weather
  Log = ::Log.for(self)

  # How long a forecast stays fresh. Weather does not change fast
  # enough to justify hammering the API from a 60-second page poll.
  CACHE_TTL = 30.minutes

  # Bounds on the outbound call so a slow API cannot hold a fragment
  # render hostage for longer than a few seconds.
  CONNECT_TIMEOUT = 3.seconds
  READ_TIMEOUT    = 5.seconds

  # One weather reading, ready to render. All values are metric:
  # degrees Celsius and kilometers per hour. Built by the module from
  # the parsed API response, not deserialized directly.
  class Snapshot
    property temperature : Float64
    property apparent : Float64?
    property humidity : Float64?
    property wind_speed : Float64?
    property code : Int32
    property daily_code : Int32?
    property temp_max : Float64?
    property temp_min : Float64?

    def initialize(
      @temperature : Float64,
      @apparent : Float64? = nil,
      @humidity : Float64? = nil,
      @wind_speed : Float64? = nil,
      @code : Int32 = 0,
      @daily_code : Int32? = nil,
      @temp_max : Float64? = nil,
      @temp_min : Float64? = nil,
    )
    end
  end

  # Cache slot: latitude, longitude, fetch time and the snapshot.
  # Protected by a mutex because Kemal answers requests concurrently.
  @@mutex = Mutex.new
  @@cache : {Float64, Float64, Time, Snapshot}? = nil

  # Returns a (possibly stale) snapshot for the coordinates, refreshing
  # the cache when it is empty, for different coordinates or expired.
  # A failed refresh falls back to whatever is cached, however old:
  # an outdated temperature beats a broken widget.
  def self.snapshot(latitude : Float64, longitude : Float64) : Snapshot?
    cached_snapshot : Snapshot? = nil
    need_fetch = true

    @@mutex.synchronize do
      if slot = @@cache
        lat, lon, fetched_at, cached = slot
        if lat == latitude && lon == longitude
          cached_snapshot = cached
          need_fetch = (Time.utc - fetched_at) >= CACHE_TTL
        end
      end
    end

    return cached_snapshot unless need_fetch

    fresh = fetch(latitude, longitude)
    @@mutex.synchronize do
      if fresh
        @@cache = {latitude, longitude, Time.utc, fresh}
        fresh
      else
        cached_snapshot
      end
    end
  end

  private def self.fetch(latitude : Float64, longitude : Float64) : Snapshot?
    uri = URI.parse(api_url(latitude, longitude))
    client = HTTP::Client.new(uri)
    client.connect_timeout = CONNECT_TIMEOUT
    client.read_timeout = READ_TIMEOUT
    # Ask for an uncompressed body: Crystal's transparent deflate
    # decoding chokes on some servers' zlib streams (observed with
    # open-meteo.com), and the forecast payload is tiny anyway.
    headers = HTTP::Headers{"Accept-Encoding" => "identity"}
    response = client.get(uri.request_target, headers: headers)
    return unless response.status.ok?
    parse(response.body)
  rescue ex : Exception
    Log.warn { "Weather fetch failed: #{ex.message}" }
    nil
  ensure
    client.try(&.close)
  end

  # The Open-Meteo forecast URL: current conditions and a 3-day daily
  # forecast, auto-detected timezone, metric units.
  private def self.api_url(latitude : Float64, longitude : Float64) : String
    params = URI::Params.build do |form|
      form.add("latitude", latitude.to_s)
      form.add("longitude", longitude.to_s)
      form.add("current", "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m")
      form.add("daily", "weather_code,temperature_2m_max,temperature_2m_min")
      form.add("forecast_days", "1")
      form.add("timezone", "auto")
    end
    "https://api.open-meteo.com/v1/forecast?#{params}"
  end

  # Parses an Open-Meteo response into a Snapshot. The API is stable
  # but this defends against partial answers: anything missing just
  # stays nil on the snapshot.
  private def self.parse(body : String) : Snapshot?
    payload = OpenMeteoResponse.from_json(body)
    daily = payload.daily
    Snapshot.new(
      temperature: payload.current.temperature_2m,
      apparent: payload.current.apparent_temperature,
      humidity: payload.current.relative_humidity_2m,
      wind_speed: payload.current.wind_speed_10m,
      code: payload.current.weather_code,
      daily_code: daily.try(&.weather_code.first?),
      temp_max: daily.try(&.temperature_2m_max.first?),
      temp_min: daily.try(&.temperature_2m_min.first?),
    )
  rescue ex : JSON::ParseException
    Log.warn { "Malformed weather response: #{ex.message}" }
    nil
  end

  # Response shape of the Open-Meteo forecast endpoint, trimmed to the
  # fields the widget shows. Internal detail, but public: the JSON
  # mapping macros can't reference private constants.
  class OpenMeteoResponse
    include JSON::Serializable

    property current : Current
    property daily : Daily? = nil

    class Current
      include JSON::Serializable

      property temperature_2m : Float64
      property apparent_temperature : Float64?
      property relative_humidity_2m : Float64?
      property weather_code : Int32 = 0
      property wind_speed_10m : Float64?
    end

    class Daily
      include JSON::Serializable

      property weather_code : Array(Int32) = [] of Int32
      property temperature_2m_max : Array(Float64) = [] of Float64
      property temperature_2m_min : Array(Float64) = [] of Float64
    end
  end

  # Human label and Material icon name for a WMO weather interpretation
  # code (Open-Meteo's vocabulary). Icons are classic Material Icons
  # ligatures so no extra font is loaded.
  DESCRIPTIONS = {
    0..0   => {"Clear sky", "wb_sunny"},
    1..1   => {"Mostly clear", "wb_sunny"},
    2..2   => {"Partly cloudy", "cloud"},
    3..3   => {"Overcast", "wb_cloudy"},
    45..48 => {"Fog", "cloud"},
    51..57 => {"Drizzle", "grain"},
    61..67 => {"Rain", "opacity"},
    71..77 => {"Snow", "ac_unit"},
    80..82 => {"Showers", "opacity"},
    85..86 => {"Snow showers", "ac_unit"},
    95..99 => {"Thunderstorm", "flash_on"},
  }

  def self.describe(code : Int32) : {String, String}
    DESCRIPTIONS.each do |range, description|
      return description if range.includes?(code)
    end
    {"Unknown", "help_outline"}
  end
end
