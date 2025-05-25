require "kemal"
require "json"
require "./journalctl"
require "baked_file_system"

module Grafito
  extend self
  # Setup a logger for this module
  Log = ::Log.for(self)

  VERSION = "0.1.0"

  # Any assets we want baked into the binary.
  class Assets
    extend BakedFileSystem
    bake_file "index.html", {{ read_file "#{__DIR__}/index.html" }}
    bake_file "favicon.svg", {{ read_file "#{__DIR__}/favicon.svg" }}
  end



  # Matches GET "http://host:port/" and serves the index.html file.
  get "/" do |env|
    env.response.content_type = "text/html"
    env.response.print Assets.get("index.html").gets_to_end
  end

  # Matches GET "http://host:port/" and serves the index.html file.
  get "/favicon.svg" do |env|
    env.response.content_type = "text/html"
    env.response.print Assets.get("favicon.svg").gets_to_end
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

    # since_param is a negative number of seconds ago.
    # If since_param is nil or >=0, it means "Any time" was selected.
    since = env.params.query["since"]?
    since = (since && !since.strip.empty?) ? since : nil

    unit = env.params.query["unit"]?
    tag = env.params.query["tag"]?
    search_query = env.params.query["q"]? # General search term from main input
    logs = Journalctl.query(since: since, unit: unit, tag: tag, query: search_query)

    env.response.content_type = "text/html" # Set content type for all responses

    if logs
      html_output = String.build do |str|
        # Added "striped" class for PicoCSS styling, and some inline style for the empty message
        str << "<table class=\"striped\">"
        str << "<thead><tr><th>Timestamp</th><th>Message</th></tr></thead>"
        str << "<tbody>"
        if logs.empty?
          str << "<tr><td colspan=\"2\" style=\"text-align: center; padding: 1em;\">No log entries found.</td></tr>"
        else
          logs.each do |entry|
            str << "<tr>"
            str << "<td>" << entry.formatted_timestamp << "</td>"
            str << "<td>" << HTML.escape(entry.message) << "</td>"
            str << "</tr>"
          end
        end
        str << "</tbody></table>"
      end
      env.response.print html_output
    else
      env.response.status_code = 500
      env.response.print "<p style=\"color: red; text-align: center; padding: 1em;\">Failed to retrieve logs. Please check server logs for more details.</p>"
    end
  end

  # Exposes the list of known service units.
  # Example usage:
  #   GET /services
  get "/services" do |env|
    Log.debug { "Received /services request" }
    service_units = Journalctl.known_service_units
    env.response.content_type = "text/html" # Changed to text/html

    if service_units
      # Build HTML options
      options_html = String.build do |sb|
        service_units.each do |unit_name|
          sb << "<option value=\"" << HTML.escape(unit_name) << "\"></option>"
        end
      end
      env.response.print options_html
    else
      env.response.status_code = 500
      # Return an HTML comment or an empty string if units can't be fetched.
      # This prevents HTMX from erroring if it expects HTML.
      env.response.print "<!-- Failed to retrieve service units -->"
    end
  end
end

# Configure logging level. :debug will show all debug messages.
# You can also use Log.setup_from_env to control it via CRYSTAL_LOG_LEVEL.
Log.setup(:debug)
Kemal.run(port: 3000)
