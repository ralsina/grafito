# # Homepage configuration
#
# The homepage view — a launcher for self-hosted apps, in the spirit
# of [gethomepage](https://gethomepage.dev) but deliberately smaller —
# is configured with a YAML file (default `/etc/grafito/homepage.yml`,
# override with `--homepage-config`):
#
# ```yaml
# title: Homelab
#
# # Hostname services declared with only a port are reached at
# # (here "port: 3000" means http://rocky:3000). Useful when the
# # machine is reachable by name — over Tailscale, say — because the
# # name keeps working from wherever you browse, unlike an IP.
# hostname: rocky
#
# weather:
#   latitude: -34.9
#   longitude: -56.16
#   location: Montevideo
#   units: metric # or imperial
#
# groups:
#   - name: Media
#     services:
#       - name: Jellyfin
#         port: 8096 # same as url: http://rocky:8096
#         description: Movies and series
#         icon: play_circle # Material icon, emoji or image URL
#         check: true # show an up/down dot for this service
#   - name: Utilities
#     services:
#       - name: Home Assistant
#         url: https://ha.example.com
# ```
#
# Everything except a service's name and one of `url` or `port` is
# optional. When the file does not exist the view renders setup
# instructions instead, so enabling the view costs nothing until it is
# configured.

require "yaml"

module HomepageConfig
  # One launchable app. `icon` accepts a Material Icons ligature name
  # ("jellyfin" does not exist, but "play_circle" does), an emoji, or
  # an image URL for the dashboard-icons crowd. `check` opts the
  # service into reachability monitoring (a colored dot).
  #
  # A service is located either by a full `url` or by a bare `port`
  # (resolved against the config's `hostname` once the whole file has
  # been parsed, so `url` always holds the final address afterwards).
  class Service
    include YAML::Serializable

    property name : String
    property url : String = ""
    property port : Int32? = nil
    property description : String = ""
    property icon : String = ""
    property? check : Bool = false

    # Explicit constructor so code can synthesize services at runtime
    # (the homepage's auto-generated "Installed apps" group).
    def initialize(name : String, url : String, description : String = "", icon : String = "", check : Bool = false)
      @name = name
      @url = url
      @description = description
      @icon = icon
      @check = check
    end
  end

  # A titled column of services, rendered as one card.
  class Group
    include YAML::Serializable

    property name : String
    property services : Array(Service) = [] of Service

    # Explicit constructor for runtime-synthesized groups (the
    # homepage's auto-generated "Installed apps" group).
    def initialize(name : String, services : Array(Service) = [] of Service)
      @name = name
      @services = services
    end
  end

  # Optional weather widget settings. Coordinates are required (they
  # are the whole point); the location name is purely cosmetic.
  class Weather
    include YAML::Serializable

    property latitude : Float64
    property longitude : Float64
    property location : String = ""
    property units : String = "metric"

    def imperial? : Bool
      units.strip.downcase == "imperial"
    end
  end

  class Config
    include YAML::Serializable

    property title : String = "Home"
    property hostname : String = ""
    property weather : Weather? = nil
    property groups : Array(Group) = [] of Group

    # True when the config has nothing at all to show: the view then
    # renders its setup hint, like a missing file would.
    def empty? : Bool
      groups.empty? && weather.nil?
    end

    # Services declared with only a port get their url built from the
    # config's hostname. Runs after the whole file is parsed so the
    # error messages can name the service and say what is missing.
    def after_initialize
      groups.each do |group|
        group.services.each do |service|
          next unless service.url.empty?
          if port = service.port
            if hostname.empty?
              raise ArgumentError.new("Service '#{service.name}' uses port #{port}, but the config sets no hostname")
            end
            service.url = "http://#{hostname}:#{port}"
          else
            raise ArgumentError.new("Service '#{service.name}' needs a url or a port")
          end
        end
      end
    end

    # Reads and parses the config file. Raises on unreadable files and
    # invalid YAML; an empty file is a valid (empty) config, which
    # YAML::Serializable has no zero-argument constructor for, hence
    # the empty mapping.
    def self.load(path : String) : Config
      raw = File.read(path)
      raw.strip.empty? ? Config.from_yaml("{}") : Config.from_yaml(raw)
    end
  end
end
