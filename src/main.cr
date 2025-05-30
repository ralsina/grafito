require "./grafito"
require "docopt"
require "kemal-basic-auth"
require "kemal"

DOC = <<-DOCOPT
Grafito - A simple log viewer.

Usage:
  grafito [options]
  grafito (-h | --help)
  grafito --version

Options:
  -p PORT, --port=PORT          Port to listen on [default: 3000].
  -b ADDRESS, --bind=ADDRESS    Address to bind to [default: 127.0.0.1].
  -h --help                     Show this screen.
  --version                     Show version.
DOCOPT

def main
  args = Docopt.docopt(DOC, ARGV, version: Grafito::VERSION)

  port = args["--port"].as(String).to_i32
  bind_address = args["--bind"].as(String)

  Log.setup(:debug) # Or use Log.setup_from_env for more flexibility
  Grafito::Log.info { "Starting Grafito server on #{bind_address}:#{port}" }
  Kemal.config.host_binding = bind_address

  # --- Basic Authentication Configuration ---
  # Read credentials and realm from environment variables
  auth_user = ENV["GRAFITO_AUTH_USER"]?
  auth_pass = ENV["GRAFITO_AUTH_PASS"]?

  if auth_user && auth_pass
    # Both username and password are set, enable basic authentication
    Grafito::Log.info { "Basic Authentication enabled. User: #{auth_user}" }
    basic_auth auth_user.as(String), auth_pass.as(String)
  elsif auth_user || auth_pass
    # Only one of the credentials was set - this is a misconfiguration.
    Grafito::Log.fatal { "Basic Authentication misconfigured: Both GRAFITO_AUTH_USER and GRAFITO_AUTH_PASS must be set if authentication is intended." }
    exit 1 # Exit with an error code to prevent running in an insecure state.
  else
    # Neither username nor password are set, run without authentication.
    Grafito::Log.warn { "Basic Authentication is DISABLED. To enable, set GRAFITO_AUTH_USER and GRAFITO_AUTH_PASS environment variables." }
  end

  Kemal.run(port: port)
end

main()
