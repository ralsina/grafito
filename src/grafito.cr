require "kemal"
require "json"
require "./journalctl"

module Grafito
  extend self
  # Setup a logger for this module
  Log = ::Log.for(self)

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
    Log.debug { "Received /logs request with query params: #{env.params.query.inspect}" }

    date = env.params.query["date"]?
    unit = env.params.query["unit"]?
    tag = env.params.query["tag"]?
    search_query = env.params.query["q"]?      # General search term from main input
    live = env.params.query["live-view"]? == "on" # From the "live-view" checkbox

    logs = Journalctl.query(date: date, unit: unit, tag: tag, live: live, query: search_query)
    if logs
      env.response.content_type = "application/json"
      env.response.print logs.to_json
    else
      env.response.status_code = 500
      env.response.print "Failed to retrieve logs"
    end
  end
end

# Configure logging level. :debug will show all debug messages.
# You can also use Log.setup_from_env to control it via CRYSTAL_LOG_LEVEL.
Log.setup(:debug)
Kemal.run(port: 3000)
