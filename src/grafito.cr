require "kemal"
require "json"
require "./journalctl"

module Grafito
  extend self
  VERSION = "0.1.0"

  # Matches GET "http://host:port/" and serves the index.html file.
  get "/" do |env|
    env.response.content_type = "text/html"
    send_file env, "./src/index.html"
  end

  # Creates a WebSocket handler.
  # Matches "ws://host:port/socket"
  ws "/socket" do |socket|
    socket.send "Hello from Kemal!"
  end

  # Exposes the Journalctl wrapper via a REST API.
  # Example usage:
  #   GET /logs?date=2024-01-15&unit=sshd.service&tag=sshd
  #   GET /logs?unit=nginx.service
  get "/logs" do |env|
    date = env.params.query["date"]?
    unit = env.params.query["unit"]?
    tag = env.params.query["tag"]?

    logs = Journalctl.query(date: date, unit: unit, tag: tag)
    if logs
      env.response.content_type = "application/json"
      env.response.print logs.to_json
    else
      env.response.status_code = 500
      env.response.print "Failed to retrieve logs"
    end

    if logs
      logs
    else
      error 500 do
        "Failed to retrieve logs"
      end
    end
  end
end

Kemal.run(port: 3000)
