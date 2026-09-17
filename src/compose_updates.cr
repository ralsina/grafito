# # Compose updates
#
# Update detection for stacks that are not managed by the app store:
# compare each service's locally pulled image digest against the
# registry's current digest for the same tag, cache the outcome per
# stack, and let the compose view render an "update available" badge
# with the existing pull+up job as the one-click follow-up.
#
# The registry side talks the v2 registry API directly (token auth for
# Docker Hub and ghcr.io, Docker-Content-Digest header with manifest
# body fallbacks, docker-config credentials for private images) — the
# same approach as [mangrullo](https://github.com/ralsina/mangrullo),
# from which this logic is adapted.
#
# Checks are on demand (a "check updates" stack action), never on a
# timer: registry round-trips are slow and rate-limited, and nobody
# wants grafito hammering Docker Hub in the background.

require "base64"
require "json"
require "http/client"
require "log"
require "mutex"
require "time"

require "./compose_status"
{% if flag?(:demo_mode) %}
  require "./fake_compose_data"
{% end %}

module ComposeUpdates
  Log = ::Log.for(self)

  extend self

  # How long a completed check stays fresh. Results older than this
  # are still shown (with their age) until a new check runs.
  RESULT_TTL = 6.hours

  DEFAULT_TAG = "latest"

  # One service's comparison outcome. The digests are kept for the
  # tooltip; `error` is set when the registry could not be reached or
  # the image has no registry digest at all (e.g. built locally).
  record Result,
    image : String,
    local_digests : Array(String),
    remote_digest : String?,
    error : String? do
    def update_available? : Bool
      return false if error
      remote = remote_digest
      return false unless remote
      !local_digests.includes?(remote)
    end

    def known? : Bool
      !error && !!remote_digest
    end
  end

  private record Entry, at : Time, results : Hash(String, Result)

  @@cache = {} of String => Entry
  @@running = Set(String).new
  @@auth_cache = {} of String => NamedTuple(token: String, expires_at: Time)
  @@config_credentials = {} of String => NamedTuple(user: String, password: String)?
  @@mutex = Mutex.new(protection: :checked)

  # The cached results for one stack, or nil when no check has run
  # (or the last one is older than RESULT_TTL — stale results read as
  # "no data", and the badge UI offers a fresh check).
  def self.results_for(stack_name : String) : Hash(String, Result)?
    @@mutex.synchronize do
      entry = @@cache[stack_name]?
      return unless entry
      return if (Time.utc - entry.at) > RESULT_TTL
      entry.results
    end
  end

  def self.running?(stack_name : String) : Bool
    @@mutex.synchronize { @@running.includes?(stack_name) }
  end

  def self.check_age(stack_name : String) : Time?
    @@mutex.synchronize do
      entry = @@cache[stack_name]?
      entry.try(&.at)
    end
  end

  # Spawns a background fiber that checks every service of the stack.
  # No-op while a check for the same stack is already running.
  def self.check_stack(stack : ComposeStatus::Stack) : Nil
    @@mutex.synchronize do
      return if @@running.includes?(stack.name)
      @@running << stack.name
    end
    spawn(name: "compose-updates(#{stack.name})") do
      results = {} of String => Result
      stack.services.each do |service|
        results[service.service] = check_service(service.image)
      rescue ex
        Log.warn(exception: ex) { "Update check failed for #{stack.name}/#{service.service}" }
        results[service.service] = Result.new(
          image: service.image, local_digests: [] of String,
          remote_digest: nil, error: ex.message,
        )
      end
      @@mutex.synchronize { @@cache[stack.name] = Entry.new(Time.utc, results) }
    ensure
      @@mutex.synchronize { @@running.delete(stack.name) }
    end
  end

  # Compares one image's local repo digest against the registry's
  # current manifest digest for the same tag.
  def self.check_service(image : String) : Result
    {% if flag?(:demo_mode) %}
      hash = image.bytes.sum(0)
      local = "sha256:demo-local-#{hash}"
      remote = hash % 3 == 0 ? "sha256:demo-remote-#{hash}" : local
      return Result.new(image: image, local_digests: [local], remote_digest: remote, error: nil)
    {% end %}
    local_digests = local_repo_digests(image)
    if local_digests.empty?
      return Result.new(image: image, local_digests: local_digests, remote_digest: nil,
        error: "no registry digest: image was built locally or pulled by digest")
    end

    remote = remote_manifest_digest(image)
    unless remote
      return Result.new(image: image, local_digests: local_digests, remote_digest: nil,
        error: "registry unreachable, private, or image not found")
    end
    Result.new(image: image, local_digests: local_digests, remote_digest: remote, error: nil)
  end

  # ## Pure helpers (spec-tested)

  # The registry digests of the locally stored image, as
  # `repo@sha256:…` strings, from `docker image inspect`.
  def self.local_repo_digests(image : String) : Array(String)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    result = Process.run("docker", args: ["image", "inspect", "--format", "{{json .RepoDigests}}", image],
      output: stdout, error: stderr)
    return [] of String unless result.success?
    parse_repo_digests(stdout.to_s)
  rescue ex
    Log.warn(exception: ex) { "docker image inspect failed for #{image}" }
    [] of String
  end

  # Parses the `{{json .RepoDigests}}` output of docker image inspect.
  def self.parse_repo_digests(output : String) : Array(String)
    Array(String).from_json(output.strip)
  rescue ex
    Log.debug(exception: ex) { "Unexpected RepoDigests output" }
    [] of String
  end

  # True when the registry's current digest is missing from the
  # image's local repo digests (digest format differences normalized).
  def self.update_available?(local_digests : Array(String), remote_digest : String?) : Bool
    return false unless remote_digest
    normalized = normalize_digest(remote_digest)
    # Repo digests are "repo@sha256:…" — compare the digest part only.
    !local_digests.any? do |digest|
      normalize_digest(digest.split("@").last || digest) == normalized
    end
  end

  # Ensures digest has a consistent sha256: prefix format.
  def self.normalize_digest(digest : String) : String
    digest.starts_with?("sha256:") ? digest : "sha256:#{digest}"
  end

  # ## Registry access (adapted from mangrullo)

  # Splits an image reference into registry host and repository path,
  # resolving Docker Hub library images and the lscr.io vanity host.
  def self.parse_registry_info(image_name : String) : {String, String}
    # The registry segment (if any) is everything before the first
    # slash; the tag is separated only after it, so registry ports
    # survive (registry.example.com:5000/app).
    if first_slash = image_name.index('/')
      prefix = image_name[0...first_slash]
      if prefix.includes?(".") || prefix.includes?(":")
        registry_host = prefix
        repository_with_tag = image_name[(first_slash + 1)..]
        repository_path = repository_with_tag.split(":").first
        if registry_host == "lscr.io"
          # lscr.io is a vanity URL redirecting to ghcr.io/linuxserver
          registry_host = "ghcr.io"
          repository_path = "linuxserver/#{repository_path}" unless repository_path.starts_with?("linuxserver/")
        end
        {registry_host, repository_path}
      else
        # Docker Hub namespace/image
        {"registry-1.docker.io", image_name.split(":").first}
      end
    else
      # Simple image name: Docker Hub library
      {"registry-1.docker.io", "library/#{image_name.split(":").first}"}
    end
  end

  # The tag of an image reference. A colon only separates the tag when
  # it appears after the last slash — otherwise it belongs to a
  # registry port (localhost:5000/my-app).
  def self.image_tag(image_name : String) : String
    last_slash = image_name.rindex('/')
    last_colon = image_name.rindex(':')
    if last_colon && (last_slash.nil? || last_colon > last_slash)
      image_name[(last_colon + 1)..]
    else
      DEFAULT_TAG
    end
  end

  # The registry's current manifest digest for the image's tag.
  def self.remote_manifest_digest(image_name : String) : String?
    # Skip raw digests (they are image IDs, not versioned images)
    return if image_name.starts_with?("sha256:")

    registry_host, repository_path = parse_registry_info(image_name)
    tag = image_tag(image_name)
    response = fetch_manifest(registry_host, repository_path, tag)
    return unless response && response.status_code == 200

    response.headers["Docker-Content-Digest"]? || extract_digest_from_manifest(response.body)
  end

  # Fetches the manifest for one tag, trying an authenticated client
  # first (Docker Hub tokens, ghcr.io tokens, docker-config
  # credentials) and falling back to anonymous access.
  private def self.fetch_manifest(registry_host : String, repository_path : String, tag : String) : HTTP::Client::Response?
    headers = HTTP::Headers{
      "Accept"     => "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json",
      "User-Agent" => "grafito/#{Grafito::VERSION}",
    }
    if client = authenticated_client(registry_host, repository_path)
      client.get("/v2/#{repository_path}/manifests/#{tag}", headers)
    else
      registry_client(registry_host).get("/v2/#{repository_path}/manifests/#{tag}", headers)
    end
  rescue ex
    Log.warn(exception: ex) { "Registry request failed for #{registry_host}/#{repository_path}:#{tag}" }
    nil
  end

  private def self.registry_client(registry_host : String) : HTTP::Client
    client = HTTP::Client.new(registry_host, 443, tls: true)
    client.connect_timeout = 5.seconds
    client.read_timeout = 10.seconds
    client
  end

  # An HTTP client with a bearer token for this repository, or nil
  # when the registry needs no (or has no working) token flow.
  private def self.authenticated_client(registry_host : String, repository_path : String) : HTTP::Client?
    token = registry_token(registry_host, repository_path)
    return unless token

    client = registry_client(registry_host)
    client.before_request do |request|
      request.headers["Authorization"] = "Bearer #{token}"
    end
    client
  end

  # Anonymous pull-scope token for the known token flows. Cached until
  # shortly before its realistic expiry.
  private def self.registry_token(registry_host : String, repository_path : String) : String?
    cache_key = "#{registry_host}:#{repository_path}"
    @@mutex.synchronize do
      if cached = @@auth_cache[cache_key]?
        return cached[:token] if cached[:expires_at] > Time.utc
      end
    end

    token_url = case registry_host
                when "registry-1.docker.io"
                  "https://auth.docker.io/token?service=registry.docker.io&scope=repository:#{repository_path}:pull"
                when "ghcr.io"
                  "https://ghcr.io/token?scope=repository:#{repository_path}:pull"
                else
                  return
                end

    headers = HTTP::Headers.new
    if credentials = docker_config_credentials(registry_host)
      headers["Authorization"] = "Basic #{Base64.strict_encode("#{credentials[:user]}:#{credentials[:password]}")}"
    end

    response = HTTP::Client.get(token_url, headers)
    return unless response.status_code == 200

    token = JSON.parse(response.body)["token"]?.try(&.as_s)
    return unless token

    @@mutex.synchronize { @@auth_cache[cache_key] = {token: token, expires_at: Time.utc + 4.minutes} }
    token
  rescue ex
    Log.warn(exception: ex) { "Failed to get registry token for #{registry_host}" }
    nil
  end

  # Credentials for a registry from the user's docker config (inline
  # "auth" entries only), memoized. nil means none found (cached too).
  private def self.docker_config_credentials(registry_host : String) : NamedTuple(user: String, password: String)?
    @@mutex.synchronize do
      return @@config_credentials[registry_host] if @@config_credentials.has_key?(registry_host)
      credentials = DockerConfigAuth.credentials_for(registry_host, DockerConfigAuth.default_config_path)
      @@config_credentials[registry_host] = credentials
      credentials
    end
  end

  # Extracts a digest from a manifest body when the
  # Docker-Content-Digest header is missing (some registries).
  private def self.extract_digest_from_manifest(manifest_body : String) : String?
    json = JSON.parse(manifest_body)
    if manifest = json["manifest"]?.try(&.as_h?)
      manifest["digest"]?.try(&.as_s)
    elsif config = json["config"]?.try(&.as_h?)
      config["digest"]?.try(&.as_s)
    end
  rescue ex
    Log.debug(exception: ex) { "Could not extract digest from manifest body" }
    nil
  end
end

# Reads registry credentials from a docker config.json (usually
# ~/.docker/config.json), so private images and authenticated Docker
# Hub pulls work instead of failing with 401 / anonymous rate limits.
#
# Only inline "auth" entries (base64 "user:password") are supported;
# credentials delegated to a credsStore helper binary cannot be read
# without invoking that helper. Ported from mangrullo.
module DockerConfigAuth
  Log = ::Log.for(self)

  alias Record = NamedTuple(user: String, password: String)

  # Find credentials for a registry host in a docker config file
  def self.credentials_for(registry_host : String, config_path : String) : Record?
    return unless File.file?(config_path)

    config = begin
      JSON.parse(File.read(config_path))
    rescue ex : JSON::ParseException
      Log.warn { "Docker config #{config_path} is not valid JSON: #{ex.message}" }
      return
    end

    auths = config["auths"]?.try(&.as_h?)
    return unless auths

    target = normalize_host(registry_host)
    auths.each do |key, entry|
      next unless normalize_host(key) == target

      auth = entry.as_h?.try(&.["auth"]?.try(&.as_s))
      next unless auth

      decoded = begin
        Base64.decode_string(auth)
      rescue Base64::Error
        Log.warn { "Skipping malformed auth entry for #{key} in #{config_path}" }
        next
      end

      user, _, password = decoded.partition(":")
      return {user: user, password: password}
    end

    nil
  end

  # Path to the current user's docker config, honoring DOCKER_CONFIG.
  def self.default_config_path : String
    base = ENV["DOCKER_CONFIG"]? || File.expand_path("~/.docker")
    File.join(base, "config.json")
  end

  # Normalize the ways a registry is spelled in config.json
  # ("https://index.docker.io/v1/", "ghcr.io/", …) down to a bare
  # host, mapping Docker Hub aliases onto one name.
  private def self.normalize_host(key : String) : String
    host = key.strip.downcase
    host = host.sub(%r{^https?://}, "")
    host = host.split('/').first
    host = "docker.io" if host == "index.docker.io" || host == "registry-1.docker.io"
    host
  end
end
