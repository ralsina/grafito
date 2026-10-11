# # Login and logout
#
# The session endpoints: a standalone, pico-styled sign-in page (no
# app shell, no JavaScript) and the logout action that destroys the
# server-side session. Together with the auth handler these replace
# the old basic-auth prompt.
#
# The page is deliberately tiny and self-contained: it links only the
# baked pico stylesheet (one of the few paths the auth handler lets
# through without a session) and a small inline style block that
# borrows grafito's dark theme colors, so signing in works exactly
# the same on a fresh install, behind a proxy, or with JS blocked.

require "html_builder"
require "kemal-session"

require "./grafito_helpers"
require "./settings_store"
require "./view_helpers"

module LoginDashboard
  extend self

  Log = ::Log.for(self)

  def self.register_routes : Nil
    login_path = Grafito.route_path("login")
    logout_path = Grafito.route_path("logout")

    # The sign-in page. Reachable without a session (the auth handler
    # allowlists it); when no credentials exist at all the handler is
    # open anyway and nobody needs this page.
    get login_path do |env|
      env.response.content_type = "text/html"
      login_page
    end

    # Verifies the form against the effective credentials. A plain
    # form POST (the page ships no JS), so success is a redirect and
    # failure a 401 re-render — the browser's native form UX.
    post login_path do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      username = env.params.body["username"]?.to_s
      password = env.params.body["password"]?.to_s
      if SettingsStore.verify_login(username, password)
        env.session.string("user", username)
        Log.info { "Login accepted for user '#{username}'" }
        env.response.status_code = 302
        env.response.headers["Location"] = "#{ViewHelpers.base_prefix}/"
      else
        Log.warn { "Login rejected for user '#{username}'" }
        # A fixed delay on failure keeps online guessing slow without
        # punishing legitimate mistypes much.
        sleep 500.milliseconds
        env.response.status_code = 401
        env.response.content_type = "text/html"
        login_page(error: "Wrong username or password.", username: username)
      end
    end

    # Ends the session. htmx callers (the Sign out button) get a 200
    # with HX-Redirect — a 302 would be followed by the XHR itself and
    # the login page swapped into the button instead of the whole
    # page. Anything else is redirected the classic way.
    get logout_path do |env|
      logout(env, login_path)
    end
    post logout_path do |env|
      logout(env, login_path)
    end
  end

  private def logout(env : HTTP::Server::Context, login_path : String) : Nil
    env.session.destroy
    if env.request.headers["HX-Request"]?
      env.response.status_code = 200
      env.response.headers["HX-Redirect"] = login_path
    else
      env.response.status_code = 302
      env.response.headers["Location"] = login_path
    end
  end

  # The complete sign-in document.
  def login_page(error : String = "", username : String = "") : String
    base = ViewHelpers.base_prefix
    HTML.build do
      tag("html", lang: "en", "data-theme": "dark") do
        tag("head") do
          # Void elements built as raw strings: html_builder has no
          # block-less generic tag, only link/input/img helpers.
          html %(<meta charset="UTF-8" />)
          html %(<meta name="viewport" content="width=device-width, initial-scale=1.0" />)
          tag("title") { text "Sign in — grafito" }
          link(rel: "stylesheet", href: "#{base}/pico.min.css")
          tag("style") { text LOGIN_PAGE_STYLE }
        end
        tag("body") do
          tag("main", class: "container login-card") do
            tag("h1", class: "login-title") { text "grafito" }
            tag("p", class: "login-subtitle") { text "Sign in to continue." }
            unless error.empty?
              tag("p", class: "login-error") { text error }
            end
            tag("form", method: "post", action: "#{base}/login", class: "login-form") do
              tag("label", for: "login-username") { text "Username" }
              input(id: "login-username", name: "username", type: "text",
                autocomplete: "username", required: "required", value: username)
              tag("label", for: "login-password") { text "Password" }
              input(id: "login-password", name: "password", type: "password",
                autocomplete: "current-password", required: "required")
              button(type: "submit") { text "Sign in" }
            end
            if SettingsStore.auth_from_env?
              tag("p", class: "login-hint") do
                text "Credentials are managed by the environment (GRAFITO_AUTH_USER / GRAFITO_AUTH_PASS)."
              end
            end
          end
        end
      end
    end
  end

  # Just enough theme to look like grafito: the dark panel palette,
  # centered card. Pico handles the form styling.
  LOGIN_PAGE_STYLE = <<-CSS
    body {
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      background: var(--pico-background-color, #11191f);
      color: var(--pico-color, #eceff4);
    }
    .login-card {
      width: 100%;
      max-width: 22rem;
      padding: 2rem 1.75rem;
      background: var(--pico-card-background-color, #181e25);
      border: 1px solid var(--pico-muted-border-color, #2a323c);
      border-radius: 8px;
      box-shadow: 0 10px 30px rgba(0, 0, 0, 0.35);
    }
    .login-title {
      margin: 0 0 0.2rem;
      font-size: 1.7rem;
    }
    .login-subtitle {
      margin: 0 0 1.2rem;
      opacity: 0.7;
    }
    .login-error {
      margin: 0 0 1rem;
      padding: 0.5rem 0.75rem;
      border-radius: 4px;
      background: rgba(183, 28, 28, 0.25);
      border: 1px solid rgba(183, 28, 28, 0.6);
    }
    .login-hint {
      margin: 1.2rem 0 0;
      font-size: 0.8rem;
      opacity: 0.6;
    }
    CSS
end
