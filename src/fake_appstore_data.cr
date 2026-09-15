# # Fake app store data
#
# The demo build (-Dfake_journal) has no network, no docker and no
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

  # One fixture install, parked on the fake "webapp" stack so the
  # badge, update and uninstall buttons appear in the demo.
  def self.installed : Array(AppStore::InstalledApp)
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

  # The demo always advertises a newer version so the update path of
  # the UI is visible.
  def self.update_available(installed : AppStore::InstalledApp) : String?
    installed.id == "whoami" ? "1.11.0" : nil
  end
end
