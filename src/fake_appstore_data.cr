# # Fake app store data
#
# The demo build (-Ddemo_mode) has no network, no docker and no
# writable data dir, but its compose view still shows the app store
# surface: a small fixture catalog, one fixture install (so the stack
# badge and its update/uninstall buttons are visible), and job output
# replayed like every other demo job. Mirrors the role of
# [fake_compose_data.cr](fake_compose_data.cr.html) for the stack list.

module FakeAppStore
  # The demo has exactly one store; its URL is never fetched.
  def self.stores : Array(AppStore::Store)
    [AppStore::Store.new(
      name: "Demo Store",
      slug: "demo",
      url: "https://demo.invalid/demo-appstore.tar.gz",
    )]
  end

  WHOAMI_CONFIG = <<-'JSON'
    {
      "id": "whoami",
      "name": "Whoami",
      "available": true,
      "port": 8380,
      "short_desc": "Tiny server that prints os, hostname and headers.",
      "description": "**Whoami** is a tiny container that echoes whatever it knows about the request: operating system, hostname, and headers.\\n\\nHandy to check that a fresh install actually answers on its port.",
      "categories": ["utilities", "development"],
      "version": "1.10.1",
      "tipi_version": 3,
      "author": "containous",
      "source": "https://github.com/traefik/whoami",
      "exposable": true,
      "form_fields": [
        {
          "type": "text",
          "label": "Greeting message",
          "env_variable": "WHOAMI_MESSAGE",
          "default": "hello from grafito",
          "hint": "Sent as the with-message response body."
        },
        {
          "type": "boolean",
          "label": "Include hostname",
          "env_variable": "WHOAMI_HOSTNAME",
          "default": true
        },
        {
          "type": "random",
          "label": "API token",
          "env_variable": "WHOAMI_TOKEN",
          "min": 16,
          "max": 16
        }
      ]
    }
    JSON

  JELLYFIN_CONFIG = <<-JSON
    {
      "id": "jellyfin",
      "name": "Jellyfin",
      "available": true,
      "port": 8096,
      "short_desc": "Media system that puts you in control of your media.",
      "description": "Jellyfin is the volunteer-built media solution: movies, shows and music to every device, no strings attached.",
      "categories": ["media"],
      "version": "10.9.11",
      "tipi_version": 42,
      "author": "jellyfin",
      "source": "https://github.com/jellyfin/jellyfin",
      "exposable": true,
      "form_fields": []
    }
    JSON

  FILEBROWSER_CONFIG = <<-JSON
    {
      "id": "filebrowser",
      "name": "File Browser",
      "available": true,
      "port": 8390,
      "short_desc": "Web file manager with a clean Material Design interface.",
      "description": "File Browser provides a file managing interface within a directory, upload, download, and share included.",
      "categories": ["utilities", "development"],
      "version": "2.27.0",
      "tipi_version": 7,
      "author": "filebrowser",
      "source": "https://github.com/filebrowser/filebrowser",
      "exposable": true,
      "form_fields": [
        {
          "type": "text",
          "label": "Interface style",
          "env_variable": "FB_THEME",
          "options": [
            {"label": "Light", "value": "light"},
            {"label": "Dark", "value": "dark"}
          ],
          "default": "dark"
        }
      ]
    }
    JSON

  UNAVAILABLE_CONFIG = <<-JSON
    {
      "id": "retired-app",
      "name": "Retired App",
      "available": false,
      "port": 9999,
      "short_desc": "Hidden from the catalog because available is false.",
      "categories": ["utilities"],
      "version": "0.0.1",
      "tipi_version": 1,
      "author": "nobody",
      "source": "https://example.invalid/retired"
    }
    JSON

  CONFIGS = [WHOAMI_CONFIG, JELLYFIN_CONFIG, FILEBROWSER_CONFIG, UNAVAILABLE_CONFIG]

  # Every *available* fixture app, sorted like the real catalog.
  def self.list_apps : Array(AppStore::AppInfo)
    apps = CONFIGS.compact_map do |json|
      AppStore::AppInfo.from_json(json)
    rescue
      nil
    end
    apps.select(&.available?).sort_by!(&.name.downcase)
  end

  def self.find_app(app_id : String) : AppStore::AppInfo?
    list_apps.find(&.id.==(app_id))
  end

  def self.description(app_id : String) : String
    find_app(app_id).try(&.description) || ""
  end

  # A generated stand-in logo for a fixture app: a rounded square in a
  # color derived from the app id, with the app's initial. Demo cards
  # go through the same <img> path as real store logos, so they look
  # right without any fetched store assets.
  def self.logo_svg(app_id : String) : String
    name = find_app(app_id).try(&.name) || app_id
    letter = name.empty? ? "?" : name[0, 1].upcase
    hue = app_id.bytes.sum(0) % 360
    <<-SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
        <rect width="64" height="64" rx="14" fill="hsl(#{hue}, 60%, 42%)"/>
        <text x="32" y="43" font-family="sans-serif" font-size="30" font-weight="bold" fill="#ffffff" text-anchor="middle">#{HTML.escape(letter)}</text>
      </svg>
      SVG
  end

  # ## Mutable demo state
  #
  # The installed-apps list is mutable so simulated installs, updates
  # and uninstalls have visible effects. Seeded with one fixture
  # install parked on the webapp stack (one tipi revision behind the
  # catalog, so the update badge shows until a simulated update).
  # Guarded: view polls and action endpoints run in fibers.

  @@installed_mutex = Mutex.new(protection: :checked)
  @@installed : Array(AppStore::InstalledApp)? = nil

  private def self.installed_seed : Array(AppStore::InstalledApp)
    [AppStore::InstalledApp.new(
      store: "demo",
      store_url: "https://demo.invalid/demo-appstore.tar.gz",
      id: "whoami",
      name: "Whoami",
      version: "1.10.1",
      tipi_version: 3,
      port: 8380,
      project_name: "webapp",
      installed_at: Time.utc.to_rfc3339,
    )]
  end

  # Every known install. Demo builds carry the fixture install so the
  # badge and its buttons are visible without docker.
  def self.installed : Array(AppStore::InstalledApp)
    @@installed_mutex.synchronize do
      (@@installed ||= installed_seed).dup
    end
  end

  # One install by compose project name, or nil.
  def self.find_installed(project_name : String) : AppStore::InstalledApp?
    @@installed_mutex.synchronize do
      (@@installed ||= installed_seed).find(&.project_name.==(project_name))
    end
  end

  # Simulates installing one catalog app: the compose project is the
  # app id, like the real renderer's. Reinstalling replaces any
  # previous install of the same app.
  def self.install(app_info : AppStore::AppInfo) : AppStore::InstalledApp
    record = AppStore::InstalledApp.new(
      store: "demo",
      store_url: "https://demo.invalid/demo-appstore.tar.gz",
      id: app_info.id,
      name: app_info.name,
      version: app_info.version,
      tipi_version: app_info.tipi_version,
      port: app_info.port || 0,
      project_name: app_info.id,
      installed_at: Time.utc.to_rfc3339,
    )
    @@installed_mutex.synchronize do
      list = @@installed ||= installed_seed
      list.reject!(&.project_name.==(record.project_name))
      list << record
    end
    record
  end

  # Simulates uninstalling an app. Returns true when one was removed.
  def self.uninstall(project_name : String) : Bool
    @@installed_mutex.synchronize do
      list = @@installed ||= installed_seed
      !list.reject!(&.project_name.==(project_name)).nil?
    end
  end

  # Simulates an app update: the install jumps to the catalog's
  # version, so the update badge disappears. Returns true when the
  # project was known.
  def self.mark_updated(project_name : String) : Bool
    @@installed_mutex.synchronize do
      list = @@installed ||= installed_seed
      record = list.find(&.project_name.==(project_name))
      return false unless record
      app_info = find_app(record.id)
      return false unless app_info

      list.delete(record)
      list << AppStore::InstalledApp.new(
        store: record.store,
        store_url: record.store_url,
        id: record.id,
        name: record.name,
        version: app_info.version,
        tipi_version: app_info.tipi_version,
        port: record.port,
        project_name: record.project_name,
        installed_at: record.installed_at,
      )
      true
    end
  end

  # The newest version the store offers for an installed app, or nil
  # when it is up to date. Data-driven: whatever the fixture catalog
  # carries is what the store "offers".
  def self.update_available(installed : AppStore::InstalledApp) : String?
    app_info = find_app(installed.id)
    if app_info && app_info.tipi_version > installed.tipi_version
      app_info.version
    end
  end

  # Restores the pristine demo installs (spec hygiene, container
  # restarts do the same for the demo site).
  def self.reset_demo_state : Nil
    @@installed_mutex.synchronize do
      @@installed = nil
    end
  end
end
