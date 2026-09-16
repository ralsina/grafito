# src/gotify/client.cr
#
# Minimal Gotify REST client. It only needs one endpoint: pushing a
# message to the application token's message stream. Uses the stdlib
# HTTP client, so it is trivially testable with webmock.

require "http/client"
require "json"
require "log"
require "uri"

require "./config"

module Grafito::Gotify
  class Client
    Log = ::Log.for(self)

    # A wedged Gotify server must never stall the metrics sampler, so
    # every phase of the request is bounded to a few seconds.
    CONNECT_TIMEOUT = 3.seconds
    READ_TIMEOUT    = 5.seconds
    WRITE_TIMEOUT   = 5.seconds

    # Sends a notification; returns true when the server accepted it.
    # Never raises: alerting must not take the sampler down.
    def send_notification(title : String, message : String) : Bool
      uri = URI.parse("#{Config.url}/message")
      body = {
        title:    title,
        message:  message,
        priority: Config.priority,
      }.to_json

      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      client.write_timeout = WRITE_TIMEOUT
      response = client.post(
        uri.request_target,
        # The token goes in a header, not the query string: URLs end up
        # in proxy and access logs.
        headers: HTTP::Headers{
          "Content-Type" => "application/json",
          "X-Gotify-Key" => Config.token,
        },
        body: body,
      )
      unless response.success?
        Log.error { "Gotify notification rejected: HTTP #{response.status_code}" }
        return false
      end
      true
    rescue ex
      Log.error(exception: ex) { "Failed to send Gotify notification" }
      false
    end
  end
end
