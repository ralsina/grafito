# # App store
#
# A Runtipi-compatible app store for the compose view: users browse the
# catalog of a Runtipi app store repo (the official
# [runtipi-appstore](https://github.com/runtipi/runtipi-appstore) or any
# third-party store in the same format) and install apps as ordinary
# Docker Compose stacks.
#
# A store is a tarball (any git host's archive endpoint works) of a
# repository laid out like Runtipi expects:
#
# ```text
# apps/<app-id>/
#   config.json          # name, port, version, form_fields, ...
#   docker-compose.yml   # ${VAR} placeholders, optional x-runtipi block
#   metadata/
#     logo.jpg
#     description.md
# ```
#
# Installing an app renders its compose file and a `.env` into a
# grafito-owned directory and runs `docker compose up -d` on it (see
# [compose_appstore.cr](compose_appstore.cr.html) for the HTTP side).
# Rendering follows Runtipi's rules as closely as a standalone compose
# manager can:
#
# * `${VAR}` interpolation is left to docker compose itself, resolved
#   from the generated `.env` via `--env-file`. The env carries the
#   Runtipi variables (`APP_PORT`, `APP_DATA_DIR`, `APP_DOMAIN`, ...)
#   plus one entry per install-time `form_fields` answer. `random`
#   fields are generated once and persist in the `.env`, like Runtipi.
# * `x-runtipi` metadata blocks (both top-level and per-service) are
#   stripped. The main service's `internal_port` becomes a
#   `${APP_PORT}:<internal>` host port mapping, which is how the app is
#   reachable. Apps without any `x-runtipi` info are assumed to be
#   plain compose files and are passed through unchanged.
# * Services get `restart: unless-stopped` unless they say otherwise,
#   and the `{{RUNTIPI_APP_ID}}` label placeholder (used by a few apps
#   for Traefik label naming) is replaced by the plain app id.
#
# Deliberately not supported: Traefik/domain exposure (apps are
# reachable on their host port instead), Runtipi's shared PostgreSQL
# instance, and per-store internal networks. Apps that depend on those
# fail at `up` time, visibly, in the job output.
#
# Grafito still only writes inside its own data dir: unpacked stores
# under `<data-dir>/appstores/`, rendered apps under
# `<data-dir>/apps/`, app data under `<data-dir>/app-data/`.

require "base64"
require "compress/gzip"
require "crystar"
require "file_utils"
require "http/client"
require "json"
require "log"
require "mutex"
require "set"
require "yaml"

module AppStore
  Log = ::Log.for(self)

  # How long an unpacked store cache is considered fresh. Syncing
  # downloads the whole store tarball, so it is deliberately lazy: the
  # catalog serves the cache and only syncs when it is empty or stale,
  # or when the user asks for a refresh.
  CACHE_TTL = 30.minutes

  # Bounds on the outbound download. Unlike the tiny weather payload,
  # a store tarball can be tens of megabytes, so the read timeout is
  # generous; the fetch runs in a job, not in a fragment render.
  CONNECT_TIMEOUT = 5.seconds
  READ_TIMEOUT    = 120.seconds

  # Download/extract ceilings. Store URLs are admin-configured, but a
  # compromised or misconfigured store should fill neither the data
  # dir nor /tmp before the sync's ensure cleanup runs.
  MAX_TARBALL_BYTES = 200 * 1024 * 1024
  MAX_ENTRY_BYTES   = 50 * 1024 * 1024

  # Whitelist for app ids and store slugs, which end up in file paths.
  # Runtipi ids are lowercase alphanumerics with dashes/underscores.
  VALID_ID = /^[a-z0-9][a-z0-9_-]*$/

  # Raised when a store sync fails (download error, malformed tarball)
  # so the calling job can surface the message in its output.
  class SyncError < Exception
  end

  # Raised when an app cannot be rendered into installable files.
  class RenderError < Exception
  end

  # One configured store: a display name, a slug used in paths and
  # URLs, and the tarball URL to fetch.
  record Store, name : String, slug : String, url : String

  # One dropdown option of a form field (`options` in config.json).
  class FormFieldOption
    include JSON::Serializable

    property label : String = ""
    property value : String = ""
  end

  # One install-time input, mirroring Runtipi's `form_fields` schema.
  class FormField
    include JSON::Serializable

    property type : String = "text"
    property label : String = ""
    property env_variable : String = ""
    property? required : Bool = false
    property default : JSON::Any? = nil
    property placeholder : String? = nil
    property hint : String? = nil
    property regex : String? = nil
    property pattern_error : String? = nil
    property min : Int32? = nil
    property max : Int32? = nil
    property encoding : String? = nil
    property options : Array(FormFieldOption)? = nil
  end

  # The parts of a Runtipi `config.json` this module acts on. Fields
  # are lenient (defaults everywhere) because third-party stores exist
  # and the official schema has grown over time.
  class AppInfo
    include JSON::Serializable

    property id : String = ""
    property name : String = ""
    property? available : Bool = true
    property port : Int32? = nil
    property short_desc : String = ""
    property description : String = ""
    property categories : Array(String) = [] of String
    property version : String = ""
    property tipi_version : Int32 = 0
    property author : String = ""
    property source : String = ""
    property website : String = ""
    property? exposable : Bool = false
    property form_fields : Array(FormField) = [] of FormField
  end

  # The provenance record written next to every installed app's
  # rendered files. It is what lets the compose view badge an
  # otherwise ordinary stack as a store app, offer updates (by
  # comparing `tipi_version` against the synced store) and uninstall.
  class InstalledApp
    include JSON::Serializable

    property store : String = ""
    property store_url : String = ""
    property id : String = ""
    property name : String = ""
    property version : String = ""
    property tipi_version : Int32 = 0
    property port : Int32 = 0
    property project_name : String = ""
    property installed_at : String = ""

    # The domain the app is reachable at when the user routed it
    # ("atuin.home.example.com"), or "" when it is only reachable on
    # its host port. Empty for apps installed without a domain — the
    # host:port baseline never requires one.
    property domain : String = ""

    # When true, the update job runs automatically for this app after
    # a store sync that ships a newer package (#98). Off by default.
    property? auto_update : Bool = false

    # JSON::Serializable only generates the pull-parser constructor
    # when every field has a default; the explicit one below is what
    # render_install and the demo fixtures use.
    def initialize(
      store : String = "",
      store_url : String = "",
      id : String = "",
      name : String = "",
      version : String = "",
      tipi_version : Int32 = 0,
      port : Int32 = 0,
      project_name : String = "",
      installed_at : String = "",
      auto_update : Bool = false,
      domain : String = "",
    )
      @store = store
      @store_url = store_url
      @id = id
      @name = name
      @version = version
      @tipi_version = tipi_version
      @port = port
      @project_name = project_name
      @installed_at = installed_at
      @auto_update = auto_update
      @domain = domain
    end

    def install_dir(root : String) : String
      AppStore.install_dir(root, store, id)
    end

    def data_dir(root : String) : String
      AppStore.app_data_dir(root, store, id)
    end

    def compose_file(root : String) : String
      File.join(install_dir(root), "docker-compose.yml")
    end

    def env_file(root : String) : String
      File.join(install_dir(root), ".env")
    end
  end

  # The outcome of validating an install form: the generated env
  # (base variables plus form field answers, ready to be written as
  # `.env`), any validation errors, and the chosen host port.
  record InputResult, env : Hash(String, String), errors : Array(String), port : Int32

  # The freshness marker written into a synced store cache.
  record SyncMarker, url : String, at : Time, app_count : Int32

  # ## Store configuration

  # Parses the `--appstores` spec: comma-separated `name=url` pairs.
  # Invalid entries are skipped with a warning rather than failing the
  # whole list.
  def self.parse_stores(spec : String) : Array(Store)
    spec.split(",").compact_map do |entry|
      name, _, url = entry.strip.partition("=")
      name = name.strip
      url = url.strip
      if name.empty? || url.empty?
        Log.warn { "Ignoring invalid app store entry '#{entry.strip}' (expected name=url)" } unless entry.strip.empty?
        next
      end
      Store.new(name: name, slug: slugify(name), url: url)
    end
  end

  # Finds a configured store by slug.
  def self.find_store(stores : Array(Store), slug : String?) : Store?
    return unless slug && slug.matches?(VALID_ID)
    stores.find(&.slug.==(slug))
  end

  # Reduces a display name to a path/URL-safe slug.
  def self.slugify(name : String) : String
    slug = name.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/-+/, "-").strip("-")
    slug.empty? ? "store" : slug
  end

  # ## Paths

  def self.stores_root(root : String) : String
    File.join(root, "appstores")
  end

  def self.apps_root(root : String) : String
    File.join(root, "apps")
  end

  def self.app_data_root(root : String) : String
    File.join(root, "app-data")
  end

  def self.store_dir(root : String, slug : String) : String
    File.join(stores_root(root), slug)
  end

  def self.install_dir(root : String, store_slug : String, app_id : String) : String
    File.join(apps_root(root), store_slug, app_id)
  end

  def self.app_data_dir(root : String, store_slug : String, app_id : String) : String
    File.join(app_data_root(root), store_slug, app_id)
  end

  # Where #97's pre-update backups of one app's data live. Backups
  # are plain tarballs named app-data-<timestamp>.tar.gz.
  def self.app_data_backups_dir(root : String, store_slug : String, app_id : String) : String
    File.join(root, "app-data-backups", store_slug, app_id)
  end

  # How many data backups to keep per app (newest wins, older pruned).
  APP_DATA_BACKUPS_TO_KEEP = 3

  # Tars the app's data directory (when it exists and is non-empty)
  # into the backups dir, pruning all but the newest
  # APP_DATA_BACKUPS_TO_KEEP. Returns the backup path, or nil when
  # there was nothing to back up.
  def self.backup_app_data(root : String, installed : InstalledApp) : String?
    data_dir = installed.data_dir(root)
    return unless Dir.exists?(data_dir)
    has_content = Dir.glob(File.join(data_dir, "**", "*")).any? { |p| File.file?(p) }
    return unless has_content

    backups_dir = app_data_backups_dir(root, installed.store, installed.id)
    Dir.mkdir_p(backups_dir)
    stamp = Time.utc.to_s("%Y%m%dT%H%M%S")
    backup_path = File.join(backups_dir, "app-data-#{stamp}.tar.gz")
    parent = File.dirname(data_dir)
    name = File.basename(data_dir)
    result = Process.run("tar", args: ["-czf", backup_path, "-C", parent, name],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    unless result.success?
      Log.error { "app-data backup failed for #{installed.project_name} (tar exit #{result.exit_code})" }
      File.delete?(backup_path)
      return
    end

    prune_app_data_backups(backups_dir)
    backup_path
  rescue ex
    Log.error(exception: ex) { "app-data backup failed for #{installed.project_name}" }
    nil
  end

  # One data backup for the UI: file name (within the app's backups
  # dir), size and modification time. Newest first.
  alias AppDataBackup = NamedTuple(name: String, bytes: Int64, created_at: Time)

  # Lists one app's data backups, newest first.
  def self.app_data_backups(root : String, installed : InstalledApp) : Array(AppDataBackup)
    dir = app_data_backups_dir(root, installed.store, installed.id)
    return [] of AppDataBackup unless Dir.exists?(dir)
    Dir.glob(File.join(dir, "app-data-*.tar.gz")).compact_map do |path|
      info = File.info?(path)
      next unless info
      {name: File.basename(path), bytes: info.size, created_at: info.modification_time}
    end.sort_by!(&.[:created_at]).reverse!
  rescue ex
    Log.warn(exception: ex) { "Could not list app-data backups" }
    [] of AppDataBackup
  end

  # Restores a named backup over the app's data directory: the
  # current data is removed, the tarball extracted in its place.
  # Only basenames of real backups in the app's own backups dir are
  # accepted, so there is no path traversal surface.
  def self.restore_app_data_backup(root : String, installed : InstalledApp, name : String) : Bool
    return false unless name.matches?(/^app-data-\d{8}T\d{6}\.tar\.gz$/)
    backup_path = File.join(app_data_backups_dir(root, installed.store, installed.id), name)
    return false unless File.file?(backup_path)

    data_dir = installed.data_dir(root)
    FileUtils.rm_rf(data_dir)
    parent = File.dirname(data_dir)
    Dir.mkdir_p(parent)
    result = Process.run("tar", args: ["-xzf", backup_path, "-C", parent],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    unless result.success?
      Log.error { "app-data restore failed for #{installed.project_name} (tar exit #{result.exit_code})" }
      return false
    end
    Log.info { "Restored app-data backup #{name} for #{installed.project_name}" }
    true
  rescue ex
    Log.error(exception: ex) { "app-data restore failed for #{installed.project_name}" }
    false
  end

  private def self.prune_app_data_backups(backups_dir : String) : Nil
    backups = Dir.glob(File.join(backups_dir, "app-data-*.tar.gz")).compact_map do |path|
      info = File.info?(path)
      info ? {path: path, at: info.modification_time} : nil
    end
    backups.sort_by!(&.[:at])

    backups.first(backups.size - APP_DATA_BACKUPS_TO_KEEP).each do |old_backup|
      File.delete?(old_backup[:path])
    end
  rescue ex
    Log.warn(exception: ex) { "Failed to prune app-data backups in #{backups_dir}" }
  end

  # Persists the #98 per-app auto-update toggle into the app's
  # app.json. Returns the updated record, or nil when the app is not
  # installed under this root.
  def self.set_auto_update(root : String, project_name : String, enabled : Bool) : InstalledApp?
    installed = find_installed(root, project_name)
    return unless installed

    installed.auto_update = enabled
    File.write(File.join(installed.install_dir(root), "app.json"), "#{installed.to_pretty_json}\n")
    Log.info { "Auto-update #{enabled ? "enabled" : "disabled"} for #{project_name}" }
    installed
  end

  def self.app_compose_path(root : String, store_slug : String, app_id : String) : String
    File.join(store_dir(root, store_slug), "apps", app_id, "docker-compose.yml")
  end

  def self.app_description_path(root : String, store_slug : String, app_id : String) : String
    File.join(store_dir(root, store_slug), "apps", app_id, "metadata", "description.md")
  end

  # The logo file, whichever extension the store ships. Returns the
  # first existing candidate, nil when the app has none.
  def self.app_logo_path(root : String, store_slug : String, app_id : String) : String?
    ["logo.jpg", "logo.jpeg", "logo.png", "logo.svg"].each do |candidate|
      path = File.join(store_dir(root, store_slug), "apps", app_id, "metadata", candidate)
      return path if File.exists?(path)
    end
    nil
  end

  # ## Syncing

  # Downloads and unpacks the store tarball unless a fresh cache
  # exists (or `force` is set). Returns the number of apps the store
  # carries. Raises `SyncError` on hard failures.
  def self.sync(store : Store, root : String, force : Bool = false) : Int32
    SYNC_MUTEX.synchronize do
      if @@syncing.includes?(store.slug)
        raise SyncError.new("Store '#{store.name}' is already being synced")
      end
      @@syncing.add(store.slug)
    end
    sync_locked(store, root, force)
  ensure
    SYNC_MUTEX.synchronize { @@syncing.delete(store.slug) }
  end

  @@syncing = Set(String).new
  SYNC_MUTEX = Mutex.new(protection: :checked)

  private def self.sync_locked(store : Store, root : String, force : Bool) : Int32
    target = store_dir(root, store.slug)
    marker = read_sync_marker(target)
    if !force && marker && marker.url == store.url && (Time.utc - marker.at) < CACHE_TTL
      return marker.app_count
    end

    staging = "#{target}.staging-#{Random::Secure.hex(4)}"
    tarball = File.tempname("grafito-store", ".tar.gz")
    FileUtils.mkdir_p(staging)
    begin
      download_tarball(store.url, tarball)
      unpack_tarball(tarball, staging)
      if Dir.exists?(target)
        old = "#{target}.old-#{Random::Secure.hex(4)}"
        FileUtils.mv(target, old)
        FileUtils.mv(staging, target)
        FileUtils.rm_rf(old)
      else
        FileUtils.mv(staging, target)
      end
    ensure
      FileUtils.rm_rf(staging)
      FileUtils.rm_rf(tarball)
    end

    count = list_apps(store, root).size
    File.write(File.join(target, "sync.json"), {
      url:       store.url,
      synced_at: Time.utc.to_rfc3339,
      app_count: count,
    }.to_json)
    count
  end

  # True when the store has a usable cache on disk (however old).
  def self.synced?(store : Store, root : String) : Bool
    !read_sync_marker(store_dir(root, store.slug)).nil?
  end

  # When the cache was last synced, for the UI's freshness hint.
  def self.last_sync(store : Store, root : String) : Time?
    read_sync_marker(store_dir(root, store.slug)).try(&.at)
  end

  private def self.read_sync_marker(store_cache_dir : String) : SyncMarker?
    path = File.join(store_cache_dir, "sync.json")
    return unless File.exists?(path)
    raw = JSON.parse(File.read(path))
    url = raw["url"]?.try(&.as_s?) || return
    at = raw["synced_at"]?.try(&.as_s?).try { |text| Time.parse_rfc3339(text) } || return
    count = raw["app_count"]?.try(&.as_i?) || 0
    SyncMarker.new(url: url, at: at, app_count: count)
  rescue ex : Exception
    Log.warn { "Ignoring unreadable store sync marker #{path}: #{ex.message}" }
    nil
  end

  private def self.download_tarball(url : String, path : String) : Nil
    uri = URI.parse(url)
    client = HTTP::Client.new(uri)
    client.connect_timeout = CONNECT_TIMEOUT
    client.read_timeout = READ_TIMEOUT
    # Uncompressed transfer: the payload is already a .tar.gz.
    headers = HTTP::Headers{"Accept-Encoding" => "identity"}
    client.get(uri.request_target, headers: headers) do |response|
      unless response.status.ok?
        raise SyncError.new("HTTP #{response.status.code} fetching #{url}")
      end
      File.open(path, "w") do |file|
        copied = IO.copy(response.body_io, file, MAX_TARBALL_BYTES + 1)
        if copied > MAX_TARBALL_BYTES
          raise SyncError.new("Store tarball from #{url} exceeds the #{MAX_TARBALL_BYTES}-byte size limit.")
        end
      end
    end
  rescue ex : SyncError
    raise ex
  rescue ex : Exception
    raise SyncError.new("Failed to download #{url}: #{ex.message}")
  ensure
    client.try(&.close)
  end

  private def self.unpack_tarball(tarball_path : String, staging : String) : Nil
    File.open(tarball_path) do |file|
      Compress::Gzip::Reader.open(file) do |gzip|
        Crystar::Reader.open(gzip) do |tar|
          tar.each_entry do |entry|
            extract_entry(entry, staging)
          end
        end
      end
    end
  rescue ex : SyncError
    raise ex
  rescue ex : Exception
    raise SyncError.new("Malformed store tarball: #{ex.message}")
  end

  # Extracts one regular file. Only files under apps/ are kept (docs,
  # CI scripts and dotfiles are skipped), symlinks and other special
  # entries are skipped outright, and the resolved path must stay
  # inside the staging dir (defends against path traversal entries).
  private def self.extract_entry(entry : Crystar::Header, staging : String) : Nil
    return unless entry.flag == Crystar::REG.ord
    relative = strip_top_component(entry.name)
    return if relative.empty?
    return unless relative.starts_with?("apps/")

    if entry.size > MAX_ENTRY_BYTES
      raise SyncError.new("Store entry '#{relative}' declares #{entry.size} bytes, over the #{MAX_ENTRY_BYTES}-byte limit.")
    end

    destination = File.expand_path(File.join(staging, relative))
    return unless destination.starts_with?(File.expand_path(staging) + File::SEPARATOR)

    Dir.mkdir_p(File.dirname(destination))
    File.open(destination, "w") do |file|
      copied = IO.copy(entry.io, file, MAX_ENTRY_BYTES + 1)
      if copied > MAX_ENTRY_BYTES
        raise SyncError.new("Store entry '#{relative}' exceeds the #{MAX_ENTRY_BYTES}-byte size limit.")
      end
    end
  end

  # Tarballs from git hosts carry a single top-level directory
  # (repo-branch/); everything below it is the actual content.
  private def self.strip_top_component(path : String) : String
    parts = path.split(File::SEPARATOR, remove_empty: true)
    parts[1..].join(File::SEPARATOR)
  end

  # ## The catalog

  # Every available app in a synced store, sorted by name.
  def self.list_apps(store : Store, root : String) : Array(AppInfo)
    apps_dir = File.join(store_dir(root, store.slug), "apps")
    return [] of AppInfo unless Dir.exists?(apps_dir)
    apps = Dir.glob(File.join(apps_dir, "*", "config.json")).compact_map do |config_path|
      app = AppInfo.from_json(File.read(config_path))
      app.id = File.basename(File.dirname(config_path))
      app
    rescue ex : JSON::ParseException
      Log.warn { "Skipping malformed app config #{config_path}: #{ex.message}" }
      nil
    end
    apps.select(&.available?).sort_by!(&.name.downcase)
  end

  # One app from a synced store, by id.
  def self.find_app(store : Store, root : String, app_id : String) : AppInfo?
    return unless app_id.matches?(VALID_ID)
    path = File.join(store_dir(root, store.slug), "apps", app_id, "config.json")
    return unless File.exists?(path)
    app = AppInfo.from_json(File.read(path))
    app.id = app_id
    app
  rescue ex : JSON::ParseException
    Log.warn { "Malformed app config for #{app_id}: #{ex.message}" }
    nil
  end

  # The long description of an app, when the store ships one.
  def self.app_description(store : Store, root : String, app_id : String) : String
    path = app_description_path(root, store.slug, app_id)
    File.exists?(path) ? File.read(path) : ""
  end

  # The store-side AppInfo for an installed app, or nil when the store
  # cache is empty or no longer carries the app.
  def self.store_app_for(root : String, installed : InstalledApp) : AppInfo?
    store = Store.new(name: installed.store, slug: installed.store, url: installed.store_url)
    find_app(store, root, installed.id)
  end

  # ## Installing

  # Validates the install form (port, domain and one entry per form
  # field, keyed by env variable name) and builds the app's env.
  # Runtipi semantics: required fields must be answered, unset
  # optional fields fall back to their default or are omitted, and
  # `random` fields get a generated secret that then lives in the
  # app's `.env` for its whole lifetime.
  # ameba:disable Metrics/CyclomaticComplexity
  def self.validate_input(
    app : AppInfo,
    port_param : String?,
    domain_param : String?,
    field_values : Hash(String, String),
    root : String,
  ) : InputResult
    errors = [] of String

    port_value = port_param.presence || app.port.try(&.to_s) || ""
    port = port_value.to_i?
    if port.nil? || port < 1 || port > 65_535
      errors << "Port must be a number between 1 and 65535."
      port = 0
    end

    domain = domain_param.presence || "localhost:#{port > 0 ? port : app.port}"
    env = {
      "APP_PORT"         => port.to_s,
      "APP_ID"           => app.id,
      "APP_NAME"         => app.name,
      "APP_VERSION"      => app.version,
      "APP_PROTOCOL"     => "http",
      "APP_DOMAIN"       => domain,
      "APP_EXPOSED"      => domain_param.presence ? "true" : "false",
      "ROOT_FOLDER_HOST" => root,
      "TZ"               => ENV["TZ"]?.presence || "UTC",
    } of String => String

    app.form_fields.each do |field|
      key = field.env_variable
      next if key.empty?

      resolved = resolve_field(field, field_values).presence
      if resolved.nil? && (default_value = scalar_default(field.default))
        resolved = default_value
      end
      if resolved.nil?
        errors << "#{field.label.presence || key} is required." if field.required?
        next
      end

      errors.concat(validate_field_value(field, resolved))
      env[key] = resolved
    end

    InputResult.new(env: env, errors: errors, port: port)
  end

  # The raw answer for one form field, before default/required
  # handling: random fields are generated, booleans are normalized.
  private def self.resolve_field(field : FormField, field_values : Hash(String, String)) : String?
    case field.type
    when "random"
      field_values[field.env_variable]? || generate_random(field)
    when "boolean"
      submitted = field_values[field.env_variable]?
      if submitted
        (submitted == "true" || submitted == "on" || submitted == "1") ? "true" : "false"
      elsif field.default.try(&.raw) == true
        "true"
      else
        "false"
      end
    else
      field_values[field.env_variable]?
    end
  end

  # Field-level checks shared by install (fresh user input) and
  # update (values carried over from the previous .env).
  # ameba:disable Metrics/CyclomaticComplexity
  private def self.validate_field_value(field : FormField, value : String) : Array(String)
    errors = [] of String
    label = field.label.presence || field.env_variable

    if options = field.options
      errors << "#{label} has an invalid option." unless options.any?(&.value.==(value))
    end

    if field.type == "number" && value.to_i64?.nil?
      errors << "#{label} must be a number."
    end

    if regex = field.regex.presence
      begin
        pattern = Regex.new(regex)
        unless pattern.matches?(value)
          errors << (field.pattern_error.presence || "#{label} has an invalid format.")
        end
      rescue ex : Regex::Error
        Log.warn { "App form field #{field.env_variable} has an invalid regex: #{ex.message}" }
      end
    end

    if (min = field.min) && value.size < min
      errors << "#{label} must be at least #{min} characters long."
    end
    if (max = field.max) && value.size > max
      errors << "#{label} must be at most #{max} characters long."
    end

    errors
  end

  # Generates a persistent secret for a `random` form field. Length
  # comes from the field's min/max bounds (Runtipi uses them as the
  # generated length), encoding from the field's `encoding`.
  private def self.generate_random(field : FormField) : String
    length = (field.min || field.max || 32).clamp(1, 256)
    if field.encoding == "base64"
      Base64.strict_encode(Random::Secure.random_bytes(length))[0, length]
    else
      Random::Secure.hex((length + 1) // 2)[0, length]
    end
  end

  private def self.scalar_default(default : JSON::Any?) : String?
    return unless default
    case value = default.raw
    when String then value
    when Bool   then value.to_s
    when Int    then value.to_s
    when Float  then value.to_s
    end
  end

  # Renders an app into installable files: the transformed compose
  # file, the generated `.env`, and the app.json provenance record.
  def self.render_install(store : Store, app : AppInfo, input : InputResult, root : String) : InstalledApp
    compose_source = app_compose_path(root, store.slug, app.id)
    unless File.exists?(compose_source)
      raise RenderError.new("App '#{app.id}' is not in the store cache; sync the store first.")
    end

    rendered = transform_compose(File.read(compose_source), app.id, fallback_port: app.port)
    installed = InstalledApp.new(
      store: store.slug,
      store_url: store.url,
      id: app.id,
      name: app.name,
      version: app.version,
      tipi_version: app.tipi_version,
      port: input.port,
      project_name: app.id,
      installed_at: Time.utc.to_rfc3339,
      domain: input.env["APP_EXPOSED"]? == "true" ? input.env["APP_DOMAIN"]? || "" : "",
    )

    dir = install_dir(root, store.slug, app.id)
    Dir.mkdir_p(dir)
    # The .env carries generated secrets and the installer's answers:
    # only the process owner may read it (the dir too — under a
    # DynamicUser the data dir would otherwise be world-traversable).
    File.chmod(dir, 0o700)
    File.write(File.join(dir, "docker-compose.yml"), rendered)
    File.write(File.join(dir, ".env"), env_file_content(input.env), perm: 0o600)
    File.write(File.join(dir, "app.json"), "#{installed.to_pretty_json}\n")
    installed
  end

  # The `docker compose` prefix for an installed app: explicit file
  # and env, and a stable project name, so commands never depend on
  # the working directory.
  def self.compose_command(root : String, installed : InstalledApp, *args : String) : Array(String)
    ["docker", "compose",
     "--project-name", installed.project_name,
     "-f", installed.compose_file(root),
     "--env-file", installed.env_file(root)] + args.to_a
  end

  # Re-renders an installed app from the synced store when the store
  # carries a newer package version. User-answered env values are
  # carried over from the existing `.env`. Returns human-readable
  # status lines for the job output.
  def self.prepare_update(root : String, installed : InstalledApp) : Array(String)
    app = store_app_for(root, installed)
    unless app
      return ["App '#{installed.id}' is no longer in the store; keeping current files."]
    end
    if app.tipi_version <= installed.tipi_version
      return ["Store package unchanged (#{app.name} #{app.version}); pulling images only."]
    end

    previous_env = begin
      parse_env_file(File.read(installed.env_file(root)))
    rescue ex : Exception
      Log.warn { "Could not re-read .env of #{installed.project_name}: #{ex.message}" }
      {} of String => String
    end
    port = previous_env["APP_PORT"]? || installed.port.to_s
    domain = previous_env["APP_DOMAIN"]?
    input = validate_input(app, port, domain, previous_env, root)

    merged = input.env
    previous_env.each do |key, value|
      merged[key] = value unless merged.has_key?(key)
    end

    installed.tipi_version = app.tipi_version
    installed.version = app.version
    installed.port = input.port
    installed.domain = merged["APP_EXPOSED"]? == "true" ? (merged["APP_DOMAIN"]? || "") : ""
    dir = install_dir(root, installed.store, installed.id)
    Dir.mkdir_p(dir)
    File.chmod(dir, 0o700)
    File.write(installed.compose_file(root), transform_compose(File.read(app_compose_path(root, installed.store, app.id)), app.id, fallback_port: app.port))
    File.write(installed.env_file(root), env_file_content(merged), perm: 0o600)
    File.write(File.join(dir, "app.json"), "#{installed.to_pretty_json}\n")

    messages = ["Updated app files: #{app.name} #{app.version} (package v#{app.tipi_version})."]
    input.errors.each do |error|
      messages << "Warning: #{error} (add it to the app's .env to configure it)"
    end
    messages
  end

  # Removes an installed app's rendered files, and optionally its
  # data directory. Containers must already be down.
  def self.remove_install(root : String, installed : InstalledApp, delete_data : Bool) : Nil
    FileUtils.rm_rf(installed.install_dir(root))
    FileUtils.rm_rf(installed.data_dir(root)) if delete_data
  end

  # Every installed app, across all stores, sorted by project name.
  def self.installed(root : String) : Array(InstalledApp)
    base = apps_root(root)
    return [] of InstalledApp unless Dir.exists?(base)
    apps = Dir.glob(File.join(base, "*", "*", "app.json")).compact_map do |path|
      InstalledApp.from_json(File.read(path))
    rescue ex : Exception
      Log.warn { "Skipping unreadable installed app record #{path}: #{ex.message}" }
      nil
    end
    apps.sort_by!(&.project_name)
  end

  def self.find_installed(root : String, project_name : String) : InstalledApp?
    installed(root).find(&.project_name.==(project_name))
  end

  # ## Env files

  # Serializes env entries as a docker-compose-compatible env file.
  # Newlines would corrupt the file format, so they become spaces;
  # every other character docker's dotenv parser handles verbatim.
  def self.env_file_content(env : Hash(String, String)) : String
    String.build do |io|
      env.each do |key, value|
        io << key << "=" << value.gsub(/\r\n|\r|\n/, " ") << "\n"
      end
    end
  end

  # Reads back an env file (update flow reuses the user's answers).
  # Understands `KEY=VALUE` lines, comments, and matching single or
  # double quotes around values.
  # ameba:disable Metrics/CyclomaticComplexity
  def self.parse_env_file(content : String) : Hash(String, String)
    result = {} of String => String
    content.each_line do |line|
      line = line.strip
      next if line.empty? || line.starts_with?("#")
      key, separator, value = line.partition("=")
      next if separator.empty? || key.strip.empty?
      value = value.strip
      if value.size >= 2 && value.starts_with?('"') && value.ends_with?('"')
        value = value[1..-2]
      elsif value.size >= 2 && value.starts_with?("'") && value.ends_with?("'")
        value = value[1..-2]
      end
      result[key.strip] = value
    end
    result
  end

  # ## Compose transformation

  # Turns a store app's docker-compose.yml into a standalone one:
  # strips x-runtipi metadata, adds the host port mapping and a
  # restart policy, substitutes the {{RUNTIPI_APP_ID}} label
  # placeholder, and re-dumps the YAML.
  # ameba:disable Metrics/CyclomaticComplexity
  def self.transform_compose(compose_source : String, app_id : String, fallback_port : Int32? = nil) : String
    doc = YAML.parse(compose_source)
    root = doc.as_h?
    raise RenderError.new("compose file is not a YAML mapping") unless root

    root.delete(YAML::Any.new("x-runtipi"))

    main_service : Hash(YAML::Any, YAML::Any)? = nil
    main_port : Int32? = nil
    other_ports = [] of Int32
    other_mains = [] of Hash(YAML::Any, YAML::Any)

    if services = root["services"]?.try(&.as_h?)
      services.each_value do |service_any|
        service = service_any.as_h?
        next unless service

        if metadata = service.delete(YAML::Any.new("x-runtipi"))
          if metadata_h = metadata.as_h?
            internal = yaml_int(metadata_h[YAML::Any.new("internal_port")]?)
            is_main = yaml_bool(metadata_h[YAML::Any.new("is_main")]?)
            if internal
              if is_main
                main_service = service
                main_port = internal
              else
                other_ports << internal
                other_mains << service
              end
            end
          end
        end

        unless service["restart"]?
          service[YAML::Any.new("restart")] = YAML::Any.new("unless-stopped")
        end
        substitute_placeholders(service, app_id)
      end
    end

    chosen_port = main_port
    chosen_service = main_service
    if chosen_port.nil? && other_ports.uniq.size == 1
      chosen_port = other_ports[0]
      chosen_service = other_mains[0]
    end
    # Last resort: a single-service app with no x-runtipi metadata but
    # a UI port in its config.json (18 store apps publish nothing
    # without this — they assume Runtipi's traefik routes them by
    # domain). With more than one service the target is ambiguous and
    # the app stays as authored.
    if chosen_port.nil? && (fallback = fallback_port).try(&.>(0))
      if services = root["services"]?.try(&.as_h?)
        if services.size == 1 && (service = services.first_value.as_h?)
          chosen_port = fallback
          chosen_service = service
        end
      end
    end
    if (port = chosen_port) && (service = chosen_service)
      service[YAML::Any.new("ports")] = YAML.parse(%(["${APP_PORT}:#{port}"]))
    end

    localize_networks(root)
    root.to_yaml
  rescue ex : RenderError
    raise ex
  rescue ex : Exception
    raise RenderError.new("Malformed app compose file: #{ex.message}")
  end

  # Replaces {{RUNTIPI_APP_ID}} in a service's labels (both the map
  # and the list-of-strings forms). Everything else passes through.
  # Store apps reference Runtipi's shared `tipi_main_network`, which
  # runtipi declares (external) in a common compose file a standalone
  # install does not have. Every network a service references is made
  # project-local: undeclared names get a declaration, and external
  # declarations lose the external flag, so docker compose creates
  # them as <project>_<name> on `up`. Multi-service apps that declare
  # their own internal networks keep them (still local, still shared
  # between the app's services).
  # ameba:disable Metrics/CyclomaticComplexity
  private def self.localize_networks(root : Hash(YAML::Any, YAML::Any)) : Nil
    referenced = Set(String).new
    if services = root["services"]?.try(&.as_h?)
      services.each_value do |service_any|
        next unless service = service_any.as_h?
        networks = service["networks"]?
        next unless networks
        if list = networks.as_a?
          list.each { |item| referenced << item.as_s if item.as_s? }
        elsif map = networks.as_h?
          map.each_key { |key| referenced << key.as_s if key.as_s? }
        end
      end
    end
    return if referenced.empty?

    networks_key = YAML::Any.new("networks")
    declarations = root[networks_key]?.try(&.as_h?) || {} of YAML::Any => YAML::Any
    referenced.each do |name|
      key = YAML::Any.new(name)
      declaration = declarations[key]?.try(&.as_h?)
      # A declaration without an external marker already describes a
      # local network (custom subnet etc.) and is kept as-is.
      next if declaration && declaration["external"]?.nil?
      declarations[key] = YAML::Any.new({} of YAML::Any => YAML::Any)
    end
    root[networks_key] = YAML::Any.new(declarations)
  end

  private def self.substitute_placeholders(service : Hash(YAML::Any, YAML::Any), app_id : String) : Nil
    labels_key = YAML::Any.new("labels")
    labels = service[labels_key]?
    return unless labels

    if map = labels.as_h?
      substituted = map.map { |key, value| {substitute(key, app_id), substitute(value, app_id)} }.to_h
      service[labels_key] = YAML::Any.new(substituted)
    elsif list = labels.as_a?
      service[labels_key] = YAML::Any.new(list.map { |item| substitute(item, app_id) })
    end
  end

  private def self.substitute(value : YAML::Any, app_id : String) : YAML::Any
    raw = value.raw
    return YAML::Any.new(raw.gsub("{{RUNTIPI_APP_ID}}", app_id)) if raw.is_a?(String)
    value
  end

  private def self.yaml_int(value : YAML::Any?) : Int32?
    return unless value
    case raw = value.raw
    when Int    then raw.to_i32
    when Float  then raw.to_i32
    when String then raw.to_i32?
    end
  end

  private def self.yaml_bool(value : YAML::Any?) : Bool
    return false unless value
    raw = value.raw
    raw == true || raw == "true"
  end
end
