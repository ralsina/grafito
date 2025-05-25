require "docopt"
require "kemal"
require "./grafito" # To access Grafito::VERSION and Grafito::Log

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
  Kemal.run(port: port)
end

main()
