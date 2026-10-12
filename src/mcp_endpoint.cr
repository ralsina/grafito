# # Grafito's MCP endpoint
#
# Wires the [mcp](https://github.com/ralsina/mcp) shard's Kemal handler
# into grafito's route table at `POST <base>/mcp` (JSON-RPC) and
# `GET <base>/mcp` (SSE). Authentication is grafito's own: a bearer
# token set via `--mcp-token` / `GRAFITO_MCP_TOKEN`. Fail-closed — with
# no token configured the endpoint reports itself disabled, and the
# auth handler lets the path through only so the token check can run.

require "kemal"
require "mcp"

require "./grafito"
require "./mcp_tools"

module Grafito::McpEndpoint
  Log = ::Log.for(self)

  # True when a token is configured: the endpoint exists only then.
  def self.enabled? : Bool
    !Grafito.mcp_token.nil?
  end

  # Constant-time bearer-token check.
  def self.authorized?(env : HTTP::Server::Context) : Bool
    token = Grafito.mcp_token
    header = env.request.headers["Authorization"]?
    return false unless token && header
    match = header.match(/^Bearer (.+)$/)
    return false unless match
    Crypto::Subtle.constant_time_compare(
      Digest::SHA256.digest(match[1].strip),
      Digest::SHA256.digest(token),
    )
  end

  # Providers gluing the mcp shard to grafito.
  class TokenAuth < MCP::AuthProvider
    def get_user_id(env) : String
      McpEndpoint.authorized?(env) ? "mcp-client" : "anonymous"
    end

    def authenticate?(env) : Bool
      McpEndpoint.authorized?(env)
    end
  end

  class GrafitoLog < MCP::LogProvider
    def info(&)
      Log.info { yield }
    end

    def error(message : String, exception : Exception? = nil)
      Log.error(exception: exception) { message }
    end

    def debug(message : String)
      Log.debug { message }
    end

    def warn(message : String)
      Log.warn { message }
    end
  end

  class GrafitoConfig < MCP::MCPConfig
    def enabled? : Bool
      McpEndpoint.enabled?
    end

    def protocol_version : String
      "2024-11-05"
    end

    def server_name : String
      "grafito"
    end

    def server_version : String
      Grafito::VERSION
    end
  end

  @@handler : MCP::Handler? = nil

  # The configured handler (tools come from MCP's registry, filled by
  # mcp_tools.cr at require time).
  def self.handler : MCP::Handler
    @@handler ||= MCP::Handler.new(TokenAuth.new, GrafitoLog.new, MCP::Server.new(GrafitoConfig.new, GrafitoLog.new))
  end
end
