# src/gotify/config.cr
#
# Configuration for Gotify notifications. The feature is completely
# optional: unless both GRAFITO_GOTIFY_URL and GRAFITO_GOTIFY_TOKEN are
# set, no alerts are evaluated or sent.
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

    # The integration is enabled only when both the server URL and the
    # application token are configured.
    def enabled? : Bool
      !url.blank? && !token.blank?
    end

    # Base URL of the Gotify server, without trailing slash.
    def url : String
      raw = (ENV["GRAFITO_GOTIFY_URL"]? || "").strip
      raw.empty? ? "" : raw.rstrip('/')
    end

    def token : String
      (ENV["GRAFITO_GOTIFY_TOKEN"]? || "").strip
    end

    def priority : Int32
      ENV["GRAFITO_GOTIFY_PRIORITY"]?.try(&.to_i?) || 5
    end

    def disk_threshold_pct : Float64
      ENV["GRAFITO_ALERT_DISK_PCT"]?.try(&.to_f?) || 90.0
    end

    def swap_threshold_pct : Float64
      ENV["GRAFITO_ALERT_SWAP_PCT"]?.try(&.to_f?) || 90.0
    end

    def errors_per_min_threshold : Float64
      ENV["GRAFITO_ALERT_ERRORS_PER_MIN"]?.try(&.to_f?) || 10.0
    end
  end
end
