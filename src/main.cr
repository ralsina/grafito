# [markdown]
# # Grafito
#
# Welcome to the Grafito source code! I will try to make this code have
# comments in the literate programming style, so when passing it through
# a tool such as [crycco](https://crycco.ralsina.me) it will turn into
# a readable guided tour.
#
# It doesn't hurt that there is not so much code 🤣
#
# Grafito is a simple log viewer. While it tries to have a nice UI, the
# *idea* itself is simple. Your Linux system already provides a nice
# log management system in `journald` but accessing it via the terminal
# using `journalctl` is a bit old fashioned and not terribly convenient.
#
# One solution many use is to use some sort of log collection and viewing
# stack, such as Grafana and others. While those solutions make sense for
# a complex infrastructure in a company, I don´t think a personal server
# or homelab has the same requirements.
#
# Therefore, Grafito tries to expose the important bits of `journald` in
# a comfortable environment. View the logs. Filter them in the most common
# ways. Provide, when possible, escape hatches so you can just drop down
# into the more powerful terminal.
#
# Don´t try to replace the existing, built-in solution that you already
# have working, but build upon it.
#
# ALso, choose the tooling so it's easy to install, requires minimal setup
# and configuration and is performant. Easy, right?

# ## main.cr

require "./grafito"
require "baked_file_handler"
require "baked_file_system"
require "docopt"
require "kemal-basic-auth"
require "kemal"
require "log"

# This file [main.cr](main.cr.html) is the starting point for grafito. We get the instructions from the
# user about how to start via the command line, using [docopt](https://docopt.org)
# which lets us just write the help and then everything Just Works.
#
# Since one of the goals is easy setup and minimal config, there are exactly 4 configurable things:
#
# * Address
# * Port
# * User
# * Password
#
# And they are all optinal ;-)

DOC = <<-DOCOPT
Grafito - A simple log viewer.

Usage:
  grafito [options]
  grafito (-h | --help)
  grafito --version

Options:
  -p PORT, --port=PORT          Port to listen on [default: 3000].
  -b ADDRESS, --bind=ADDRESS    Address to bind to [default: 127.0.0.1].
  -U UNITS, --units=UNITS       Comma-separated list of systemd units to show (restricts access).
  --log-level=LEVEL             Set log level (debug, info, warn, error, fatal) [default: info].
  -h --help                     Show this screen.
  --version                     Show version.

Environment variables:
  GRAFITO_AUTH_USER             Username for basic authentication (if set, GRAFITO_AUTH_PASS must also be set).
  GRAFITO_AUTH_PASS             Password for basic authentication (if set, GRAFITO_AUTH_USER must also be set).
  LOG_LEVEL                     Log level (debug, info, warn, error, fatal) [default: info].
DOCOPT

# ## The Assets class
#
# Bake all files from the src/assets directory into the binary.
# The keys in the baked FS will be like "/index.html" for "assets/index.html", etc.
#
# This is important because it's what allows distributing Grafito as a single binary
# without the need to ship a bunch of files alongside it.
#
# All the things that are needed to function are baked-in:
#
# * pico.css
# * htmx
# * index.html
# * style.css
#
# We are not embedding fonts and icons because they are not strictly
# needed for Grafito to run, so if you run it without Internet access
# it will work fine but fonts will look different and icons may be missing.
class Assets
  extend BakedFileSystem
  bake_folder "./assets"
end

# This `main()`function is called from the top-level so it's code that
# always gets executed.

def main
  # We parse the command line (`ARGV`) using the help we described above.

  args = Docopt.docopt(DOC, ARGV, version: Grafito::VERSION)

  # Set log level from command line argument
  log_level = args["--log-level"].as(String).upcase
  ENV["LOG_LEVEL"] = log_level
  Log.setup_from_env

  # Port and binding address are important
  port = args["--port"].as(String).to_i32
  bind_address = args["--bind"].as(String)

  # Parse units restriction if provided
  if args["--units"]?
    units = args["--units"].as(String).split(",").map(&.strip)
    Grafito.allowed_units = units
    Grafito::Log.info { "Restricting to units: #{units.join(", ")}" }
  end

  # Log at debug level. Probably worth making it configurable.

  Log.setup(:debug) # Or use Log.setup_from_env for more flexibility
  Grafito::Log.info { "Starting Grafito server on #{bind_address}:#{port}" }
  # Start kemal listening on the right address
  Kemal.config.host_binding = bind_address

  # Read credentials and realm from environment variables
  auth_user = ENV["GRAFITO_AUTH_USER"]?
  auth_pass = ENV["GRAFITO_AUTH_PASS"]?

  # Check if Z.AI API key is available for AI features
  z_ai_api_key = ENV["Z_AI_API_KEY"]?
  if z_ai_api_key
    Grafito::Log.info { "Z.AI API key configured - AI features enabled" }
    Grafito.ai_enabled = true
  else
    Grafito::Log.info { "Z.AI API key not configured - AI features disabled" }
    Grafito.ai_enabled = false
  end

  # Both username and password are set, enable basic authentication
  if auth_user && auth_pass
    Grafito::Log.info { "Basic Authentication enabled. User: #{auth_user}" }
    basic_auth auth_user.as(String), auth_pass.as(String)
  elsif auth_user || auth_pass
    # Only one of the credentials was set - this is a misconfiguration.
    # Exit with an error code to prevent running in an insecure state.
    Grafito::Log.fatal { "Basic Authentication misconfigured: Both GRAFITO_AUTH_USER and GRAFITO_AUTH_PASS must be set if authentication is intended." }
    exit 1
  else
    # Neither username nor password are set, run without authentication.
    Grafito::Log.warn { "Basic Authentication is DISABLED. To enable, set GRAFITO_AUTH_USER and GRAFITO_AUTH_PASS environment variables." }
  end

  # The `BakedFileHandler` is a custom handler that serves files that are baked
  # into the application. In our case, the Assets class we defined above.
  #
  # You can see how it's implemented in the [baked_handler.cr](baked_handler.cr.html) file.
  baked_asset_handler = BakedFileHandler::BakedFileHandler.new(Assets)
  add_handler baked_asset_handler

  # Tell kemal to listen on the right port. That's it. The rest is done in [grafito.cr](grafito.cr.html)
  # where the kemal endpoints are defined.
  # Clear ARGV so Kemal doesn't try to parse command line arguments
  ARGV.clear
  Kemal.run(port: port)
end

main()
