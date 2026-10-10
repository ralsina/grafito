# src/gotify/config.cr
#
# Configuration for Gotify notifications. The feature is completely
# optional: unless both a server URL and an application token are
# configured, no alerts are evaluated or sent.
#
# Sources, in order: environment variables, then the settings store
# (the settings view's Notifications section), then defaults.
#
# Environment variables:
# - GRAFITO_GOTIFY_URL: Base URL of the Gotify server
#   (e.g. https://push.example.com)
# - GRAFITO_GOTIFY_TOKEN: Application token
# - GRAFITO_GOTIFY_PRIORITY: Default message priority [default: 5]
# - GRAFITO_ALERT_DISK_PCT: Disk usage alert threshold [default: 90]
# - GRAFITO_ALERT_SWAP_PCT: Swap usage alert threshold [default: 90]
# - GRAFITO_ALERT_ERRORS_PER_MIN: Error-rate alert threshold [default: 10]

module Grafito::Gotify
  module Config
    extend self

    Log = ::Log.for(self)

    # The settings store's notification section, if any. Read per
    # access so settings-view changes apply to the next evaluation.
    private def self.settings : SettingsStore::GotifySettings?
      SettingsStore.load(Grafito.data_dir).gotify
    end

    # The integration is enabled only when both the server URL and the
    # application token are configured.
    def enabled? : Bool
      !url.blank? && !token.blank?
    end

    # Base URL of the Gotify server, without trailing slash.
    def url : String
      raw = (ENV["GRAFITO_GOTIFY_URL"]? || "").strip
      raw = (settings.try(&.url) || "").strip if raw.empty?
      raw.empty? ? "" : raw.rstrip('/')
    end

    def token : String
      from_env = (ENV["GRAFITO_GOTIFY_TOKEN"]? || "").strip
      return from_env unless from_env.empty?
      (settings.try(&.token) || "").strip
    end

    def priority : Int32
      ENV["GRAFITO_GOTIFY_PRIORITY"]?.try(&.to_i?) ||
        settings.try(&.priority) || 5
    end

    def disk_threshold_pct : Float64
      ENV["GRAFITO_ALERT_DISK_PCT"]?.try(&.to_f?) ||
        settings.try(&.disk_pct) || 90.0
    end

    def swap_threshold_pct : Float64
      ENV["GRAFITO_ALERT_SWAP_PCT"]?.try(&.to_f?) ||
        settings.try(&.swap_pct) || 90.0
    end

    def errors_per_min_threshold : Float64
      ENV["GRAFITO_ALERT_ERRORS_PER_MIN"]?.try(&.to_f?) ||
        settings.try(&.errors_per_min) || 10.0
    end
  end
end
