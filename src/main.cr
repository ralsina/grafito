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

require "./baked_handler"
require "./grafito"
require "docopt"
require "kemal-basic-auth"
require "kemal"

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
  -h --help                     Show this screen.
  --version                     Show version.
DOCOPT

# This `main()`function is called from the top-level so it's code that
# always gets executed.

def main
  # We parse the command line (`ARGV`) using the help we described above.

  args = Docopt.docopt(DOC, ARGV, version: Grafito::VERSION)

  # Port and binding address are important
  port = args["--port"].as(String).to_i32
  bind_address = args["--bind"].as(String)

  # Log at debug level. Probably worth making it configurable.

  Log.setup(:debug) # Or use Log.setup_from_env for more flexibility
  Grafito::Log.info { "Starting Grafito server on #{bind_address}:#{port}" }
  # Start kemal listening on the right address
  Kemal.config.host_binding = bind_address

  # Read credentials and realm from environment variables
  auth_user = ENV["GRAFITO_AUTH_USER"]?
  auth_pass = ENV["GRAFITO_AUTH_PASS"]?

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

  # Add the BakedFileHandler to serve static assets from Grafito::Assets
  # It will serve files like /style.css and /index.html (for / requests)
  baked_asset_handler = Grafito::BakedFileHandler.new(Grafito::Assets)
  add_handler baked_asset_handler

  # Tell kemal to listen on the right port. That's it. The rest is done in [grafito.cr](grafito.cr.html)
  # where the kemal endpoints are defined.
  Kemal.run(port: port)
end

main()
