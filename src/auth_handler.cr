# # Authentication handler
#
# Login-session enforcement. Browsers authenticate by signing in at
# `/login` and carrying the (signed, HttpOnly) session cookie; the
# credentials themselves are resolved per request from the boot
# environment or the settings store, so the settings view can change
# them (and the onboarding wizard can create them) without a restart.
# When no credentials exist anywhere every request passes through,
# exactly like an unconfigured grafito always did.
#
# Sessions come from kemal-session (see `configure_sessions` in
# main.cr): the cookie only carries a signed session id, the session
# data lives server-side. A session counts only while its `user`
# matches the *current* effective username — changing the username
# invalidates every outstanding session.
#
# There is no `WWW-Authenticate` handshake and `Authorization` headers
# are ignored: the basic-auth era is over. Unauthenticated requests
# are answered according to what issued them — htmx gets a 401 with
# `HX-Redirect` (a full-page redirect to the login page, which also
# handles a session expiring mid-view), browser navigations get a
# plain 302, and anything else (curl, API clients) a plain 401.

require "http/server/handler"
require "kemal-session"

require "./settings_store"

class AuthHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    credentials = SettingsStore.effective_auth
    if credentials.nil?
      call_next(context)
    elsif session_user?(context, credentials[0])
      call_next(context)
    elsif public_path?(context.request.path)
      call_next(context)
    else
      unauthorized(context)
    end
  end

  # A valid session: present, and belonging to the current username.
  # Reading `context.session` materializes a fresh (empty) session for
  # visitors without a cookie — harmless, nothing is stored until data
  # is written.
  private def session_user?(context : HTTP::Server::Context, username : String) : Bool
    context.session.string?("user") == username
  end

  # Everything the login page itself needs: the session endpoints and
  # the pico stylesheet the page links (all other baked assets stay
  # behind auth). Base-path aware, like the routes themselves.
  private def public_path?(path : String) : Bool
    {Grafito.route_path("login"), Grafito.route_path("logout"),
     "#{Grafito.route_path("pico.min.css")}"}.includes?(path)
  end

  private def unauthorized(context : HTTP::Server::Context) : Nil
    login = Grafito.route_path("login")
    request = context.request
    if request.headers["HX-Request"]?
      context.response.status_code = 401
      context.response.headers["HX-Redirect"] = login
      context.response.print "Session expired."
    elsif request.headers["Accept"]?.to_s.includes?("text/html")
      context.response.status_code = 302
      context.response.headers["Location"] = login
    else
      context.response.status_code = 401
      context.response.print "Login required.\n"
    end
    context.response.close
  end
end
