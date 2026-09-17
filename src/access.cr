# # Access
#
# Computes how to reach an installed app: the always-present
# `http://<host>:<port>` baseline — which requires no DNS, no proxy
# and no certificates — plus the optional `https://<domain>` form
# when the user routed the app by domain. The access layer (#138) is
# additive by design: degrade to the baseline at any time and nothing
# breaks.

require "./app_store"

module Access
  # Both forms for one installed app. `internal` is always present;
  # `external` only when the app has a domain (the user's answer to
  # the install form's "Domain" field, persisted in app.json).
  record AppUrls, internal : String, external : String? do
    # The URL to point people at: the domain form when it exists,
    # host:port otherwise.
    def preferred : String
      external || internal
    end
  end

  # The host part of a request's Host header (drops any :port), since
  # the app's own port is what matters.
  def self.hostname_from(host_header : String?) : String
    host = host_header.to_s.split(":").first?
    host.nil? || host.empty? ? "localhost" : host
  end

  def self.urls(installed : AppStore::InstalledApp, hostname : String?) : AppUrls
    internal = "http://#{hostname_from(hostname)}:#{installed.port}"
    domain = installed.domain
    external = domain.empty? ? nil : "https://#{domain}"
    AppUrls.new(internal: internal, external: external)
  end
end
