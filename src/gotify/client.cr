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

    # Sends a notification; returns true when the server accepted it.
    # Never raises: alerting must not take the sampler down.
    def send_notification(title : String, message : String) : Bool
      url = "#{Config.url}/message?token=#{URI.encode_www_form(Config.token)}"
      body = {
        title:    title,
        message:  message,
        priority: Config.priority,
      }.to_json

      response = HTTP::Client.post(
        url,
        headers: HTTP::Headers{"Content-Type" => "application/json"},
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
