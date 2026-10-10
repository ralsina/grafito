# # Authentication handler
#
# Basic-auth enforcement with credentials resolved per request, so the
# settings view can change them (and the onboarding wizard can create
# them) without a restart. Replaces the boot-time `basic_auth` call:
# when no credentials exist anywhere (neither the boot environment nor
# the settings store) every request passes through, exactly like an
# unconfigured grafito always did.
#
# Requests are answered with the same 401 + `WWW-Authenticate` shape
# kemal-basic-auth used, so browsers and scripts see no difference.
# Both the username and the password are compared through SHA-256
# digests: digest comparison leaks at most digest-equality timing,
# never a plaintext prefix match.

require "crypto/subtle"
require "digest/sha256"
require "http/server/handler"

require "./settings_store"

class AuthHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    credentials = SettingsStore.effective_auth
    if credentials.nil?
      call_next(context)
    elsif authorized?(context.request.headers["Authorization"]?, credentials)
      call_next(context)
    else
      unauthorized(context)
    end
  end

  # Decodes and checks a Basic Authorization header against the
  # credentials. The username is split from the password on the first
  # colon only (passwords may contain colons).
  private def authorized?(header : String?, credentials : {String, String}) : Bool
    return false unless header && header.starts_with?("Basic ")
    decoded = decode(header)
    return false unless colon = decoded.index(':')
    user = decoded[0...colon]
    password = decoded[(colon + 1)..]
    secure_equal?(user, credentials[0]) && secure_equal?(password, credentials[1])
  end

  private def decode(header : String) : String
    Base64.decode_string(header[6..].strip)
  rescue Base64::Error | ArgumentError
    ""
  end

  # Constant-time comparison of the SHA-256 digests.
  private def secure_equal?(presented : String, expected : String) : Bool
    Crypto::Subtle.constant_time_compare(
      Digest::SHA256.digest(presented),
      Digest::SHA256.digest(expected),
    )
  end

  private def unauthorized(context : HTTP::Server::Context) : Nil
    context.response.status_code = 401
    context.response.headers["WWW-Authenticate"] = %(Basic realm="grafito", charset="UTF-8")
    context.response.print "Could not verify your access level for that URL.\nYou have to login with proper credentials"
    context.response.close
  end
end
