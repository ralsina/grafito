# # Compose app store
#
# The HTTP side of the Runtipi-compatible app store: catalog, install
# form and lifecycle endpoints, all rendered as HTMX fragments that
# live inside the compose view. The catalog and the install form open
# in the sidebar Detail panel (exactly where the YAML view opens); the
# lifecycle actions answer with the same pollable job-output fragments
# the stack actions use, so installing, updating and uninstalling an
# app streams its `docker compose` progress Dockge-style.
#
# Endpoint map:
#
# * `GET /compose-appstore` — catalog (store selector, search, app
#   cards), rendered into the Detail panel.
# * `GET /compose-appstore-app` — the install form for one app.
# * `GET /compose-appstore-logo` — an app's logo from the store cache.
# * `POST /compose-appstore-sync` — re-download a store, as a job.
# * `POST /compose-appstore-install` — validate + render + `up -d`,
#   as a job.
# * `POST /compose-appstore-update` — re-render from the store and
#   `pull && up -d`, as a job.
# * `POST /compose-appstore-uninstall` — `down` and remove the
#   rendered files (data is kept), as a job.
#
# Gating mirrors the rest of the compose view: the read-only endpoints
# need the view enabled, everything state-changing additionally needs
# `--enable-actions` plus authentication. Demo builds never touch the
# network, docker or the data dir: they serve a small fixture catalog
# and replay job output (see [fake_appstore_data.cr](fake_appstore_data.cr.html)).

require "html_builder"
require "json"
require "log"

require "./app_store"
require "./view_helpers"
require "./access"
require "./compose_dashboard"
require "./compose_jobs"

{% if flag?(:demo_mode) %}
  require "./fake_appstore_data"
  require "./fake_compose_data"
{% end %}

module ComposeAppStore
  extend self

  Log = ::Log.for(self)

  # Upper bound on cards rendered at once, so a 300-app store with a
  # one-letter search doesn't produce a megabyte fragment.
  MAX_CARDS = 100

  # ## Routes
  #
  def self.register_routes
    # The catalog. Read-only, so it only needs the compose view (and
    # the app store) enabled.
    get route_path("compose-appstore") do |env|
      unless appstore_enabled?
        env.response.status_code = 404
        next "App store is disabled."
      end
      env.response.content_type = "text/html"
      catalog_html(
        optional_query_param(env, "store"),
        optional_query_param(env, "q"),
        optional_query_param(env, "category"),
      )
    end

    # The install form for one app.
    get route_path("compose-appstore-app") do |env|
      unless appstore_enabled?
        env.response.status_code = 404
        next "App store is disabled."
      end
      store_slug = id_param(env, "store")
      app_id = id_param(env, "app")
      if store_slug.nil? || app_id.nil?
        env.response.status_code = 400
        next "Missing or invalid store/app id."
      end
      store = find_store(store_slug)
      if store.nil?
        env.response.status_code = 404
        next "Store '#{HTML.escape(store_slug)}' not found."
      end
      app = store_app(store, app_id)
      if app.nil?
        env.response.status_code = 404
        next "App '#{HTML.escape(app_id)}' not found in store."
      end
      env.response.content_type = "text/html"
      app_form_html(store, app, description: app_description_markdown(store, app),
        installed: AppStore.find_installed(Grafito.data_dir, app.id), hostname: Access.hostname_from(env.request.headers["Host"]?))
    end

    # One app's logo straight from the store cache.
    get route_path("compose-appstore-logo") do |env|
      unless appstore_enabled?
        env.response.status_code = 404
        next "App store is disabled."
      end
      store_slug = id_param(env, "store")
      app_id = id_param(env, "app")
      if store_slug.nil? || app_id.nil?
        env.response.status_code = 400
        next "Missing or invalid store/app id."
      end
      {% if flag?(:demo_mode) %}
        # Demo builds never touch the store cache: the fixture store
        # serves a generated logo (hue from the id, the app's initial)
        # so its cards look like real store cards.
        env.response.headers["Cache-Control"] = "public, max-age=300"
        env.response.content_type = "image/svg+xml"
        # An SVG fetched directly renders as a same-origin document:
        # force download semantics and a script-free sandbox so a
        # store logo can never run script in Grafito's origin.
        env.response.headers["Content-Disposition"] = "attachment; filename=logo.svg"
        env.response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; sandbox"
        next FakeAppStore.logo_svg(app_id)
      {% end %}
      logo_path = AppStore.app_logo_path(Grafito.data_dir, store_slug, app_id)
      if logo_path.nil?
        env.response.status_code = 404
        next "No logo."
      end
      env.response.headers["Cache-Control"] = "public, max-age=300"
      env.response.headers["Content-Disposition"] = "attachment; filename=logo"
      env.response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; sandbox"
      env.response.content_type = logo_content_type(logo_path)
      File.read(logo_path)
    end

    # Everything below is state-changing and requires the same gate as
    # the other compose actions.

    # Re-download a store tarball and unpack it, as a streaming job.
    post route_path("compose-appstore-sync") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless actions_allowed?
        env.response.status_code = 403
        next actions_rejected_message
      end
      store = find_store(body_param(env, "store"))
      if store.nil?
        env.response.status_code = 400
        next "Unknown store."
      end
      job_id = ComposeJobs.start_custom("sync #{store.name}") do |job|
        job.append("Downloading #{store.url} …")
        count = AppStore.sync(store, Grafito.data_dir, force: true)
        job.append("Store synced: #{count} apps available.")
        # #98: apps with the auto-update toggle get their update job
        # run right here, when the sync ships a newer package.
        {% unless flag?(:demo_mode) %}
          AppStore.installed(Grafito.data_dir).each do |installed|
            next unless installed.store == store.slug && installed.auto_update?
            store_app = AppStore.store_app_for(Grafito.data_dir, installed)
            next unless store_app && store_app.tipi_version > installed.tipi_version

            job.append("Auto-updating #{installed.project_name} (#{installed.version} → #{store_app.version}) …")
            if backup = AppStore.backup_app_data(Grafito.data_dir, installed)
              job.append("Backed up app data to #{backup}")
            end
            AppStore.prepare_update(Grafito.data_dir, installed).each do |message|
              job.append(message)
            end
            code = ComposeJobs.run_command(job, AppStore.compose_command(Grafito.data_dir, installed, "pull"))
            code = ComposeJobs.run_command(job, AppStore.compose_command(Grafito.data_dir, installed, "up", "-d")) if code == 0
            job.append(code == 0 ? "Auto-update of #{installed.project_name} finished." : "Auto-update of #{installed.project_name} failed (exit #{code}).")
          end
        {% end %}
      end
      env.response.content_type = "text/html"
      job_fragment(job_id, "appstore-sync")
    end

    # Validate the install form, render the app's files, and bring the
    # stack up — as a streaming job.
    post route_path("compose-appstore-install") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless actions_allowed?
        env.response.status_code = 403
        next actions_rejected_message
      end
      store_slug = id_param(env, "store")
      app_id = id_param(env, "app")
      if store_slug.nil? || app_id.nil?
        env.response.status_code = 400
        next "Missing or invalid store/app id."
      end

      {% if flag?(:demo_mode) %}
        # Demo build: validate against the fixture catalog, add the app
        # to the fake installed list (its stack appears in the compose
        # view) and replay the install output. No network, no docker.
        app = FakeAppStore.find_app(app_id)
        if app.nil?
          env.response.status_code = 404
          next "App '#{HTML.escape(app_id)}' not found in store."
        end

        if FakeAppStore.find_installed(app.id)
          env.response.status_code = 409
          next HTML.build do
            div(class: "service-panel service-panel-error") do
              tag("h4") { text "Already installed: #{app.name}" }
              tag("p") { text "This app is already installed. Use the stack's update button to upgrade it." }
            end
          end
        end

        installed = FakeAppStore.install(app)
        FakeComposeData.add_installed_stack(installed.project_name, app)
        Log.info { "Demo mode: app store install of #{installed.project_name} simulated" }
        job_id = ComposeJobs.start("install #{installed.project_name}", [[] of String])
        env.response.content_type = "text/html"
        next job_fragment(job_id, "appstore-install-#{installed.project_name}")
      {% else %}
        store = find_store(store_slug)
        if store.nil?
          env.response.status_code = 404
          next "Store '#{HTML.escape(store_slug)}' not found."
        end
        app = store_app(store, app_id)
        if app.nil?
          env.response.status_code = 404
          next "App '#{HTML.escape(app_id)}' not found in store (sync it first)."
        end

        if AppStore.find_installed(Grafito.data_dir, app_id)
          env.response.status_code = 409
          next HTML.build do
            div(class: "service-panel service-panel-error") do
              tag("h4") { text "Already installed: #{app.name}" }
              tag("p") { text "This app is already installed. Use the stack's update button to upgrade it." }
            end
          end
        end

        input = AppStore.validate_input(app, body_param(env, "port"), body_param(env, "domain"), form_field_values(env), Grafito.data_dir)
        if input.errors.any?
          env.response.content_type = "text/html"
          next app_form_html(store, app, input: input, description: app_description_markdown(store, app))
        end

        begin
          installed = AppStore.render_install(store, app, input, Grafito.data_dir)
        rescue ex : AppStore::RenderError
          env.response.status_code = 500
          next "Failed to render app: #{HTML.escape(ex.message.to_s)}"
        end
        commands = [
          AppStore.compose_command(Grafito.data_dir, installed, "pull"),
          AppStore.compose_command(Grafito.data_dir, installed, "up", "-d"),
        ]
        job_id = ComposeJobs.start("install #{installed.project_name}", commands)
        env.response.content_type = "text/html"
        job_fragment(job_id, "appstore-install-#{installed.project_name}")
      {% end %}
    end

    # Update an installed app from its store: re-render the files when
    # the store carries a newer package, then pull and up -d.
    post route_path("compose-appstore-update") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless actions_allowed?
        env.response.status_code = 403
        next actions_rejected_message
      end
      installed = installed_app(body_param(env, "stack"))
      if installed.nil?
        env.response.status_code = 404
        next "This stack is not an installed app."
      end

      job_id : String
      {% if flag?(:demo_mode) %}
        # Demo build: jump the install to the catalog's version so the
        # update badge clears, and replay the update output.
        FakeAppStore.mark_updated(installed.project_name)
        Log.info { "Demo mode: app store update of #{installed.project_name} simulated" }
        job_id = ComposeJobs.start("update #{installed.project_name}", [[] of String])
      {% else %}
        job_id = ComposeJobs.start_custom("update #{installed.project_name}") do |job|
          job.append("Refreshing the app store cache …")
          count = AppStore.sync(update_store(installed), Grafito.data_dir)
          job.append("Store cache holds #{count} apps.")
          # #97: snapshot the app's data before anything is re-rendered
          # or pulled, so an update can always be rolled back.
          if backup = AppStore.backup_app_data(Grafito.data_dir, installed)
            job.append("Backed up app data to #{backup}")
          end
          AppStore.prepare_update(Grafito.data_dir, installed).each do |message|
            job.append(message)
          end
          code = ComposeJobs.run_command(job, AppStore.compose_command(Grafito.data_dir, installed, "pull"))
          code = ComposeJobs.run_command(job, AppStore.compose_command(Grafito.data_dir, installed, "up", "-d")) if code == 0
          job.finish(code)
          nil
        end
      {% end %}
      env.response.content_type = "text/html"
      job_fragment(job_id, "appstore-update-#{installed.project_name}")
    end

    # Uninstall an installed app: down, then remove the rendered
    # files. App data is deliberately kept.
    post route_path("compose-appstore-uninstall") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless actions_allowed?
        env.response.status_code = 403
        next actions_rejected_message
      end
      installed = installed_app(body_param(env, "stack"))
      if installed.nil?
        env.response.status_code = 404
        next "This stack is not an installed app."
      end

      job_id : String
      {% if flag?(:demo_mode) %}
        # Demo build: drop the install (badge and buttons disappear)
        # and remove a dynamically installed stack; fixture scenery
        # stays. Replay the uninstall output.
        FakeAppStore.uninstall(installed.project_name)
        FakeComposeData.remove_installed_stack(installed.project_name)
        Log.info { "Demo mode: app store uninstall of #{installed.project_name} simulated" }
        job_id = ComposeJobs.start("uninstall #{installed.project_name}", [[] of String])
      {% else %}
        job_id = ComposeJobs.start_custom("uninstall #{installed.project_name}") do |job|
          job.append("Stopping and removing containers …")
          code = ComposeJobs.run_command(job, AppStore.compose_command(Grafito.data_dir, installed, "down", "--remove-orphans"))
          if code == 0
            AppStore.remove_install(Grafito.data_dir, installed, delete_data: false)
            job.append("Uninstalled #{installed.project_name}. Data kept in #{installed.data_dir(Grafito.data_dir)}")
          else
            job.append("docker compose down failed (exit #{code}); app files kept.")
          end
          job.finish(code)
          nil
        end
      {% end %}
      env.response.content_type = "text/html"
      job_fragment(job_id, "appstore-uninstall-#{installed.project_name}")
    end

    # #97: restores a named app-data backup (the current data
    # directory is replaced by the tarball's contents).
    post route_path("compose-appstore-restore-backup") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless actions_allowed?
        env.response.status_code = 403
        next actions_rejected_message
      end
      installed = installed_app(body_param(env, "stack"))
      if installed.nil?
        env.response.status_code = 404
        next "This stack is not an installed app."
      end
      backup = body_param(env, "backup") || ""

      restored = {% if flag?(:demo_mode) %}
                   # Demo: nothing on disk to restore; report success for the flow.
                   backup.matches?(/^app-data-\d{8}T\d{6}\.tar\.gz$/)
                 {% else %}
                   AppStore.restore_app_data_backup(Grafito.data_dir, installed, backup)
                 {% end %}

      env.response.content_type = "text/html"
      HTML.build do
        div(class: "service-panel") do
          tag("h4") { text restored ? "Backup restored: #{installed.name}" : "Restore failed: #{installed.name}" }
          tag("p") do
            if restored
              text "The app data directory was replaced with #{backup}. Restart the app (stop + up) so it picks the data up."
            else
              text "The backup could not be restored (missing or failed)."
            end
          end
        end
      end
    end

    # #98: flips the per-app auto-update toggle (persisted in the
    # app's app.json). Enabled apps update themselves during store
    # syncs when a newer package ships.
    post route_path("compose-appstore-auto-update") do |env|
      if Grafito.reject_cross_site_post?(env)
        halt env, status_code: 403, response: "Cross-site request rejected."
      end
      unless actions_allowed?
        env.response.status_code = 403
        next actions_rejected_message
      end
      project_name = body_param(env, "stack")
      if project_name.nil? || !project_name.matches?(AppStore::VALID_ID)
        env.response.status_code = 400
        next "Missing or invalid app id."
      end
      enabled = body_param(env, "enabled") == "true"

      {% if flag?(:demo_mode) %}
        env.response.content_type = "text/html"
        next HTML.build do
          div(class: "service-panel") do
            tag("h4") { text "Auto-update #{enabled ? "enabled" : "disabled"}: #{project_name}" }
            tag("p") { text "Demo mode: the toggle is simulated and not persisted." }
          end
        end
      {% else %}
        installed = AppStore.set_auto_update(Grafito.data_dir, project_name, enabled)
        unless installed
          env.response.status_code = 404
          next "This stack is not an installed app."
        end
        store = find_store(installed.store)
        app = store.nil? ? nil : store_app(store, installed.id)
        if store.nil? || app.nil?
          env.response.content_type = "text/html"
          next HTML.build do
            div(class: "service-panel") do
              tag("h4") { text "Auto-update #{enabled ? "enabled" : "disabled"}: #{installed.name}" }
              tag("p") { text "The setting is saved, but the store is not configured anymore, so the app view is unavailable." }
            end
          end
        end
        env.response.content_type = "text/html"
        app_form_html(store, app, installed: installed)
      {% end %}
    end
  end

  # ## Route helpers

  private def self.appstore_enabled? : Bool
    Grafito.compose_enabled? && Grafito.apps_enabled?
  end

  # The gate for state-changing endpoints, mirroring the compose
  # dashboard's: view enabled, and actions either explicitly enabled
  # with authentication or simulated on a demo build.
  private def self.actions_allowed? : Bool
    Grafito.compose_enabled? && Grafito.apps_enabled? && Grafito.actions_available?
  end

  private def self.actions_rejected_message : String
    "App store actions are disabled. Start grafito with --enable-actions and authentication configured (GRAFITO_AUTH_USER/GRAFITO_AUTH_PASS) to allow them."
  end

  # Reads a required, whitelisted id parameter (form body, falling
  # back to the query string). Ids end up in file paths, so anything
  # malformed yields nil and the route answers 400.
  private def self.id_param(env : HTTP::Server::Context, key : String) : String?
    value = env.params.body[key]? || optional_query_param(env, key)
    if value.is_a?(String) && value.matches?(AppStore::VALID_ID)
      value
    end
  end

  private def self.optional_query_param(env : HTTP::Server::Context, key : String) : String?
    Grafito.optional_query_param(env, key)
  end

  private def self.body_param(env : HTTP::Server::Context, key : String) : String?
    env.params.body[key]? || optional_query_param(env, key)
  end

  # Form fields arrive prefixed (field_SOME_VAR) so they can never
  # collide with the endpoint's own parameters.
  private def self.form_field_values(env : HTTP::Server::Context) : Hash(String, String)
    values = {} of String => String
    env.params.body.each do |key, value|
      values[key["field_".size..]] = value if key.starts_with?("field_")
    end
    values
  end

  private def self.stores : Array(AppStore::Store)
    {% if flag?(:demo_mode) %}
      FakeAppStore.stores
    {% else %}
      AppStore.parse_stores(Grafito.appstores_spec)
    {% end %}
  end

  private def self.find_store(store_slug : String?) : AppStore::Store?
    AppStore.find_store(stores, store_slug)
  end

  private def self.store_catalog(store : AppStore::Store) : Array(AppStore::AppInfo)
    {% if flag?(:demo_mode) %}
      FakeAppStore.list_apps
    {% else %}
      AppStore.list_apps(store, Grafito.data_dir)
    {% end %}
  end

  private def self.store_app(store : AppStore::Store, app_id : String) : AppStore::AppInfo?
    {% if flag?(:demo_mode) %}
      FakeAppStore.find_app(app_id)
    {% else %}
      AppStore.find_app(store, Grafito.data_dir, app_id)
    {% end %}
  end

  private def self.store_synced?(store : AppStore::Store) : Bool
    {% if flag?(:demo_mode) %}
      true
    {% else %}
      AppStore.synced?(store, Grafito.data_dir)
    {% end %}
  end

  private def self.store_description(store : AppStore::Store, app_id : String) : String
    {% if flag?(:demo_mode) %}
      FakeAppStore.description(app_id)
    {% else %}
      AppStore.app_description(store, Grafito.data_dir, app_id)
    {% end %}
  end

  # Installed-app lookups. Demo builds carry one fixture install so
  # the badge and its buttons are visible without docker.
  private def self.installed_app(project_name : String?) : AppStore::InstalledApp?
    return unless project_name
    {% if flag?(:demo_mode) %}
      FakeAppStore.find_installed(project_name)
    {% else %}
      AppStore.find_installed(Grafito.data_dir, project_name)
    {% end %}
  end

  private def self.update_store(installed : AppStore::InstalledApp) : AppStore::Store
    AppStore::Store.new(name: installed.store, slug: installed.store, url: installed.store_url)
  end

  # The polling fragment for a started job, or a plain error block if
  # the job could not be created at all.
  private def self.job_fragment(job_id : String, anchor : String) : String
    job = ComposeJobs.find(job_id)
    unless job
      return ComposeDashboard.action_error_fragment("App store", "job", "Failed to start the job.")
    end
    ComposeDashboard.output_fragment(job, anchor)
  end

  private def self.logo_content_type(path : String) : String
    case File.extname(path).downcase
    when ".png"  then "image/png"
    when ".svg"  then "image/svg+xml"
    when ".webp" then "image/webp"
    else              "image/jpeg"
    end
  end

  private def self.route_path(path : String) : String
    Grafito.route_path(path)
  end

  private def self.base : String
    ViewHelpers.base_prefix
  end

  # ## Fragments

  # The catalog: store selector, search box, category chips, app
  # cards. Everything posts back into the Detail panel.
  # ameba:disable Metrics/CyclomaticComplexity
  private def self.catalog_html(
    store_slug : String?,
    query : String?,
    category : String?,
  ) : String
    all_stores = stores
    selected = AppStore.find_store(all_stores, store_slug) || all_stores.first?
    if selected.nil?
      return HTML.build do
        div(class: "service-panel") do
          tag("h4") { text "App store" }
          tag("p") { text "No app stores configured. Set --appstores (or GRAFITO_APPSTORES) to a name=url pair pointing at a Runtipi app store tarball." }
        end
      end
    end

    # After the nil check above, selected is a plain Store.
    store = selected
    synced = store_synced?(store)
    apps = synced ? store_catalog(store) : [] of AppStore::AppInfo
    apps = filter_apps(apps, query, category)
    HTML.build do
      div(class: "service-panel appstore-panel") do
        tag("h4") { text "App store" }

        form(
          class: "appstore-filter",
          "hx-get": "#{base}/compose-appstore",
          "hx-target": "#panel-detail-content",
          "hx-swap": "innerHTML",
          "hx-trigger": "input delay:400ms, change",
          "hx-indicator": "#loading-spinner",
        ) do
          if all_stores.size > 1
            # `select` is a Crystal keyword, so the tag goes through
            # the generic tag() DSL method; the attrs go as a hash
            # because a `name:` kwarg would collide with tag()'s own
            # name parameter.
            tag("select", {"name" => "store"}) do
              all_stores.each do |candidate|
                if candidate.slug == store.slug
                  option(value: candidate.slug, selected: "selected") { text candidate.name }
                else
                  option(value: candidate.slug) { text candidate.name }
                end
              end
            end
          else
            input(type: "hidden", name: "store", value: store.slug)
          end
          input(type: "search", name: "q", value: query || "", placeholder: "Search apps…", "aria-label": "Search apps")
        end

        div(class: "appstore-categories") do
          html category_chip(store.slug, nil, category, query)
          categories_in(apps).each do |name|
            html category_chip(store.slug, name, category, query)
          end
        end

        div(id: "appstore-sync-area") do
          if synced
            html sync_status_line(store)
          else
            div(class: "appstore-not-synced") do
              tag("p") { text "This store has not been downloaded yet." }
              if Grafito.actions_available?
                button(
                  class: "service-panel-explain",
                  "hx-post": "#{base}/compose-appstore-sync",
                  "hx-vals": %({"store": "#{store.slug}"}),
                  "hx-target": "#appstore-sync-area",
                  "hx-swap": "innerHTML",
                  "hx-indicator": "#loading-spinner",
                ) do
                  text "Download store"
                end
              end
            end
          end
        end

        if apps.empty?
          div(class: "appstore-empty") do
            text synced ? "No apps match." : "Sync the store to browse its catalog."
          end
        else
          div(class: "appstore-list") do
            shown = apps[0, MAX_CARDS]
            shown.each do |app|
              html app_card(store, app)
            end
            if apps.size > MAX_CARDS
              tag("p", class: "appstore-truncated") { text "Showing the first #{MAX_CARDS} of #{apps.size} apps; refine the search to see more." }
            end
          end
        end
      end
    end
  end

  private def self.filter_apps(apps : Array(AppStore::AppInfo), query : String?, category : String?) : Array(AppStore::AppInfo)
    result = apps
    if needle = query.try(&.downcase.presence)
      result = result.select do |app|
        app.name.downcase.includes?(needle) ||
          app.short_desc.downcase.includes?(needle) ||
          app.description.downcase.includes?(needle)
      end
    end
    if wanted = category.presence
      result = result.select { |app| app.categories.any?(&.==(wanted)) }
    end
    result
  end

  private def self.categories_in(apps : Array(AppStore::AppInfo)) : Array(String)
    apps.flat_map(&.categories).uniq!.sort!
  end

  private def self.category_chip(store_slug : String, name : String?, selected : String?, query : String?) : String
    is_selected = (name || "") == (selected || "")
    params = URI::Params.build do |form|
      form.add("store", store_slug)
      form.add("category", name) if name
      form.add("q", query) if query.try(&.presence)
    end
    HTML.build do
      a(
        class: "appstore-chip#{is_selected ? " appstore-chip-active" : ""}",
        href: "#",
        "hx-get": "#{base}/compose-appstore?#{params}",
        "hx-target": "#panel-detail-content",
        "hx-swap": "innerHTML",
        "hx-indicator": "#loading-spinner",
      ) do
        text name || "All"
      end
    end
  end

  private def self.sync_status_line(store : AppStore::Store) : String
    HTML.build do
      div(class: "appstore-synced") do
        if last = AppStore.last_sync(store, Grafito.data_dir)
          span(class: "appstore-synced-at") { text "Store cache synced #{time_ago(last)}" }
        end
        if Grafito.actions_available?
          button(
            class: "service-panel-explain",
            title: "Re-download the store tarball",
            "hx-post": "#{base}/compose-appstore-sync",
            "hx-vals": %({"store": "#{store.slug}"}),
            "hx-target": "#appstore-sync-area",
            "hx-swap": "innerHTML",
            "hx-indicator": "#loading-spinner",
          ) do
            text "Refresh store"
          end
        end
      end
    end
  end

  # Store-provided links end up in the operator's authenticated
  # session: only http(s) URLs are rendered, anything else
  # (javascript:, data:, ...) degrades to plain text.
  private def self.safe_external_url(url : String?) : String
    url ||= ""
    url.matches?(/^https?:\/\//i) ? url : ""
  end

  private def self.app_card(store : AppStore::Store, app : AppStore::AppInfo) : String
    HTML.build do
      div(class: "appstore-card") do
        html app_logo(store, app)
        div(class: "appstore-card-body") do
          div(class: "appstore-card-title") do
            strong { text app.name }
            span(class: "tag tag-muted") { text app.version }
          end
          tag("p") { text app.short_desc }
          if Grafito.actions_available?
            button(
              class: "service-panel-explain",
              "hx-get": "#{base}/compose-appstore-app?store=#{URI.encode_path(store.slug)}&app=#{URI.encode_path(app.id)}",
              "hx-target": "#panel-detail-content",
              "hx-swap": "innerHTML",
              "hx-indicator": "#loading-spinner",
              "hx-on:htmx:before-request": "panelSpinner('panel-detail-content')",
              "hx-on:htmx:after-request": "if(event.detail.successful){showLogPanel('detail')}else{panelError('panel-detail-content',event.detail.xhr.status);showLogPanel('detail')}",
            ) do
              text "Install"
            end
          end
        end
      end
    end
  end

  # True when the store cache ships a logo file for the app. Demo
  # builds always say yes: their logo endpoint generates an SVG per
  # fixture app, so demo cards look like real store cards.
  private def self.logo_present?(store_slug : String, app_id : String) : Bool
    {% if flag?(:demo_mode) %}
      true
    {% else %}
      !AppStore.app_logo_path(Grafito.data_dir, store_slug, app_id).nil?
    {% end %}
  end

  private def self.app_logo(store : AppStore::Store, app : AppStore::AppInfo) : String
    if logo_present?(store.slug, app.id)
      logo_url = "#{base}/compose-appstore-logo?store=#{URI.encode_path(store.slug)}&app=#{URI.encode_path(app.id)}"
      HTML.build do
        img(src: logo_url, alt: "", class: "appstore-logo")
      end
    else
      HTML.build do
        div(class: "appstore-logo appstore-logo-fallback") do
          text app.name[0, 1].upcase
        end
      end
    end
  end

  # Store descriptions usually open with "# <App Name>", which would
  # duplicate the panel header once rendered as markdown. Trim that
  # leading title when it matches the app's name.
  private def self.app_description_markdown(store : AppStore::Store, app : AppStore::AppInfo) : String
    description = store_description(store, app.id).lstrip
    first_line, newline, rest = description.partition("\n")
    if newline.empty? || !first_line.starts_with?("# ")
      return description
    end
    first_line[2..].strip.downcase == app.name.downcase ? rest : description
  end

  # The #97/#98 section of an installed app's store view: the
  # auto-update toggle and the app-data backup list with restore
  # buttons.
  private def self.installed_app_section(
    store : AppStore::Store,
    installed : AppStore::InstalledApp,
    hostname : String? = nil,
  ) : String
    backups = AppStore.app_data_backups(Grafito.data_dir, installed)
    urls = Access.urls(installed, hostname)
    HTML.build do
      div(class: "appstore-installed") do
        span(class: "stat-label") { text "Installed" }
        span(class: "tag tag-ok") { text "v#{installed.version}" }
        a(href: urls.preferred, target: "_blank", rel: "noopener", class: "round-button",
          title: "Open #{installed.name} (#{urls.preferred})") do
          span(class: "material-icons", style: "vertical-align: middle; font-size: 1rem;") do
            text "open_in_new"
          end
        end

        form(class: "appstore-auto-update", style: "display: inline") do
          input(type: "hidden", name: "stack", value: installed.project_name)
          input(type: "hidden", name: "enabled", value: installed.auto_update? ? "false" : "true")
          button(
            class: "round-button",
            title: installed.auto_update? ? "Auto-update is on: a store sync will update this app automatically. Click to turn it off." : "Turn on auto-update: a store sync will update this app automatically.",
            "hx-post": "#{base}/compose-appstore-auto-update",
            "hx-include": "closest form",
            "hx-target": "#panel-detail-content",
            "hx-swap": "innerHTML",
            "hx-indicator": "#loading-spinner",
          ) do
            text installed.auto_update? ? "auto-update: on" : "auto-update: off"
          end
        end
      end

      div(class: "appstore-backups") do
        span(class: "stat-label") { text "App data backups" }
        if backups.empty?
          span(class: "service-panel-hint") do
            text "None yet — one is taken automatically before each update."
          end
        else
          backups.each do |backup|
            div(class: "appstore-backup-row") do
              span(class: "compose-update-service") do
                text "#{backup[:name]} (#{backup[:bytes] / 1024} KiB)"
              end
              form(style: "display: inline") do
                input(type: "hidden", name: "stack", value: installed.project_name)
                input(type: "hidden", name: "backup", value: backup[:name])
                button(
                  class: "round-button",
                  title: "Replace the app's data directory with this backup",
                  "hx-post": "#{base}/compose-appstore-restore-backup",
                  "hx-include": "closest form",
                  "hx-target": "#panel-detail-content",
                  "hx-swap": "innerHTML",
                  "hx-indicator": "#loading-spinner",
                  "hx-confirm": "Restore #{backup[:name]}? The current app data directory is replaced.",
                ) do
                  text "restore"
                end
              end
            end
          end
        end
      end
    end
  end

  # The install form: port, optional domain, the app's form fields,
  # and the (sanitized) markdown description. `input` carries the
  # previously submitted values when re-rendered with errors.
  # ameba:disable Metrics/CyclomaticComplexity
  private def self.app_form_html(
    store : AppStore::Store,
    app : AppStore::AppInfo,
    input : AppStore::InputResult? = nil,
    installed : AppStore::InstalledApp? = nil,
    description : String? = nil,
    hostname : String? = nil,
  ) : String
    port_value = input ? (input.port > 0 ? input.port.to_s : "") : app.port.try(&.to_s) || ""
    domain_value = input ? input.env["APP_DOMAIN"]? || "" : ""
    description = description || store_description(store, app.id)
    HTML.build do
      div(class: "service-panel appstore-panel") do
        div(class: "appstore-form-header") do
          html app_logo(store, app)
          tag("h4") { text app.name }
        end
        div(class: "service-panel-pills") do
          span(class: "tag tag-muted") { text app.version }
          app.categories.each do |category|
            span(class: "tag tag-info") { text category }
          end
        end

        div(class: "appstore-desc", id: "appstore-desc-#{app.id}") do
          text description
        end
        tag("script") do
          # Raw, not text(): the payload is JS, and escaping it would
          # make htmx's script evaluation die on &-escaped tokens.
          html description_script(app.id, description)
        end

        div(class: "service-panel-info") do
          unless app.author.empty?
            div do
              span(class: "stat-label") { text "Author" }
              span { text app.author }
            end
          end
          source_url = safe_external_url(app.source)
          unless source_url.empty?
            div do
              span(class: "stat-label") { text "Source" }
              a(href: source_url, rel: "noopener noreferrer") { text "repository" }
            end
          end
          website_url = safe_external_url(app.website)
          unless website_url.empty?
            div do
              span(class: "stat-label") { text "Website" }
              a(href: website_url, rel: "noopener noreferrer") { text app.website }
            end
          end
        end

        if errors = input.try(&.errors)
          unless errors.empty?
            div(class: "service-panel-error appstore-errors") do
              errors.each do |error|
                tag("p") { text error }
              end
            end
          end
        end

        if installed
          html installed_app_section(store, installed, hostname)
        end

        form(class: "appstore-install-form", id: "appstore-install-form") do
          input(type: "hidden", name: "store", value: store.slug)
          input(type: "hidden", name: "app", value: app.id)

          div(class: "appstore-field") do
            label(for: "appstore-port") { text "Port" }
            input(type: "number", id: "appstore-port", name: "port", value: port_value, min: "1", max: "65535")
          end
          div(class: "appstore-field") do
            label(for: "appstore-domain") { text "Domain (optional)" }
            input(type: "text", id: "appstore-domain", name: "domain", value: domain_value, placeholder: "localhost:#{port_value}")
          end

          app.form_fields.each do |field|
            html form_field(field, input)
          end

          if Grafito.actions_available?
            button(
              class: "service-panel-explain appstore-install-button",
              type: "button",
              "hx-post": "#{base}/compose-appstore-install",
              "hx-include": "#appstore-install-form",
              "hx-target": "#panel-detail-content",
              "hx-swap": "innerHTML",
              "hx-indicator": "#loading-spinner",
            ) do
              text "Install #{app.name}"
            end
          end
        end

        button(
          class: "service-panel-explain",
          "hx-get": "#{base}/compose-appstore?store=#{URI.encode_path(store.slug)}",
          "hx-target": "#panel-detail-content",
          "hx-swap": "innerHTML",
          "hx-indicator": "#loading-spinner",
        ) do
          text "← Back to the catalog"
        end
      end
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity
  private def self.form_field(field : AppStore::FormField, input : AppStore::InputResult?) : String
    name = "field_#{field.env_variable}"
    submitted = input.try(&.env[field.env_variable]?)
    HTML.build do
      div(class: "appstore-field") do
        label(for: name) { text field.label.presence || field.env_variable }
        if options = field.options
          tag("select", {"name" => name, "id" => name}) do
            options.each do |option|
              if submitted == option.value
                option(value: option.value, selected: "") { text option.label }
              else
                option(value: option.value) { text option.label }
              end
            end
          end
        elsif field.type == "boolean"
          if input.nil?
            # Fresh form: checked only when the field defaults to true.
            if field.default.try(&.raw) == true
              input(type: "checkbox", id: name, name: name, checked: "checked", value: "true")
            else
              input(type: "checkbox", id: name, name: name, value: "true")
            end
          elsif submitted == "true"
            input(type: "checkbox", id: name, name: name, checked: "checked", value: "true")
          else
            input(type: "checkbox", id: name, name: name, value: "true")
          end
        else
          html_type = field.type == "password" ? "password" : (field.type == "number" ? "number" : "text")
          input(type: html_type, id: name, name: name, value: submitted || "", placeholder: field.placeholder || "")
        end
        if hint = field.hint.presence
          tag("small") { text hint }
        end
      end
    end
  end

  # The description is rendered client-side through the existing
  # sanitizing markdown renderer; the raw markdown is embedded as a
  # JSON string with every "<" escaped to \u003c, so the text can
  # neither close its own script tag nor open HTML comment/script
  # parsing states inside it.
  private def self.description_script(app_id : String, description : String) : String
    payload = description.to_json.gsub("<", "\\u003c")
    <<-JS
      (function () {
        var el = document.getElementById("appstore-desc-#{app_id}");
        if (!el || !window.renderSafeMarkdown) return;
        el.innerHTML = window.renderSafeMarkdown(#{payload});
        // Store descriptions hotlink screenshots that routinely rot
        // (the URL starts serving HTML instead of the image). Replace
        // broken ones with their alt text instead of a broken-image
        // glyph.
        el.querySelectorAll("img").forEach(function (img) {
          img.loading = "lazy";
          img.style.maxWidth = "100%";
          var markMissing = function () {
            var note = document.createElement("span");
            note.className = "appstore-desc-img-missing";
            note.textContent = img.alt || "(screenshot unavailable)";
            img.replaceWith(note);
          };
          img.addEventListener("error", markMissing);
          if (img.complete && img.naturalWidth === 0) markMissing();
        });
      })( );
      JS
  end

  private def self.time_ago(time : Time) : String
    seconds = (Time.utc - time).total_seconds.to_i
    if seconds < 90
      "just now"
    elsif seconds < 3600
      "#{seconds // 60} min ago"
    elsif seconds < 86_400
      "#{seconds // 3600} h ago"
    else
      "#{seconds // 86_400} d ago"
    end
  end
end
