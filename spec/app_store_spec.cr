require "./spec_helper"
require "compress/gzip"
require "crystar"

# Unit specs for the app store core: store list parsing, form input
# validation, env files, compose transformation, and the sync +
# install + update lifecycle against a real (in-memory) tarball.
# The tarball download goes through webmock, so these run offline.

# Builds a gzipped tar with the given path => content files, the way a
# git host's archive endpoint serves a store repo.
def build_store_tarball(files : Hash(String, String)) : IO::Memory
  tar = IO::Memory.new
  Crystar::Writer.open(tar) do |tar_writer|
    files.each do |name, content|
      header = Crystar::Header.new(
        flag: Crystar::REG.ord.to_u8,
        name: name,
        size: content.bytesize.to_i64,
      )
      tar_writer.write_header(header)
      tar_writer.write(content.to_slice)
    end
  end
  tar.pos = 0
  gzipped = IO::Memory.new
  Compress::Gzip::Writer.open(gzipped) do |gzip|
    IO.copy(tar, gzip)
  end
  gzipped.pos = 0
  gzipped
end

TEST_STORE = AppStore::Store.new(
  name: "Test Store",
  slug: "test-store",
  url: "https://stores.example/test.tar.gz",
)

WHOAMI_CONFIG = <<-JSON
  {
    "id": "whoami",
    "name": "Whoami",
    "available": true,
    "port": 8380,
    "short_desc": "Tiny server that prints os, hostname and headers.",
    "description": "**Whoami** is a tiny container.",
    "categories": ["utilities"],
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
        "default": "hello"
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

X_RUNTIPI_COMPOSE = <<-YAML
  services:
    whoami:
      image: traefik/whoami:v1.10.1
      x-runtipi:
        internal_port: 80
        is_main: true
      networks:
        - tipi_main_network
      labels:
        traefik.http.routers.{{RUNTIPI_APP_ID}}.rule: Host(`whoami`)
  x-runtipi:
    schema_version: 2
  YAML

LEGACY_COMPOSE = <<-YAML
  services:
    legacy:
      image: example/legacy:1.0
      ports:
        - ${APP_PORT}:8080
  YAML

describe AppStore do
  describe ".parse_stores" do
    it "parses name=url pairs and slugifies names" do
      stores = AppStore.parse_stores("Official=https://x.example/a.tar.gz, my shop=https://y.example/b.tar.gz")
      stores.size.should eq(2)
      stores[0].slug.should eq("official")
      stores[1].slug.should eq("my-shop")
    end

    it "skips invalid entries" do
      AppStore.parse_stores("no-url-here, =https://x.example, ,ok=https://ok.example").size.should eq(1)
    end

    it "falls back to a safe slug for symbol-only names" do
      AppStore.slugify("///").should eq("store")
    end
  end

  describe ".find_store" do
    it "finds stores by slug and rejects invalid slugs" do
      stores = AppStore.parse_stores("test=https://x.example/a.tar.gz")
      AppStore.find_store(stores, "test").should_not be_nil
      AppStore.find_store(stores, "-evil").should be_nil
      AppStore.find_store(stores, nil).should be_nil
    end
  end

  describe ".validate_input" do
    app = AppStore::AppInfo.from_json(WHOAMI_CONFIG)

    it "builds the base env and applies defaults" do
      result = AppStore.validate_input(app, "8080", nil, {} of String => String, "/data")
      result.errors.should be_empty
      result.port.should eq(8080)
      result.env["APP_PORT"].should eq("8080")
      result.env["APP_DOMAIN"].should eq("localhost:8080")
      result.env["APP_ID"].should eq("whoami")
      result.env["WHOAMI_MESSAGE"].should eq("hello")
    end

    it "generates a persistent random value with the field's length" do
      result = AppStore.validate_input(app, "8080", nil, {} of String => String, "/data")
      token = result.env["WHOAMI_TOKEN"]?
      fail "WHOAMI_TOKEN missing" if token.nil?
      token.size.should eq(16)
    end

    it "keeps user answers over defaults" do
      result = AppStore.validate_input(app, "8080", nil, {"WHOAMI_MESSAGE" => "custom"}, "/data")
      result.env["WHOAMI_MESSAGE"].should eq("custom")
    end

    it "rejects invalid ports" do
      result = AppStore.validate_input(app, "70000", nil, {} of String => String, "/data")
      result.errors.size.should eq(1)
      result.port.should eq(0)
    end

    it "uses the config port when the form sends none" do
      result = AppStore.validate_input(app, "", nil, {} of String => String, "/data")
      result.port.should eq(8380)
    end
  end

  describe "field validation" do
    field_config = <<-JSON
      {
        "id": "strict",
        "name": "Strict",
        "port": 8000,
        "form_fields": [
          {"type": "number", "label": "Count", "env_variable": "COUNT", "required": true},
          {"type": "text", "label": "Code", "env_variable": "CODE", "regex": "^[a-z]+$", "min": 3, "max": 5},
          {"type": "text", "label": "Mode", "env_variable": "MODE", "options": [
            {"label": "Fast", "value": "fast"},
            {"label": "Slow", "value": "slow"}
          ]}
        ]
      }
      JSON
    strict = AppStore::AppInfo.from_json(field_config)

    it "flags missing required fields" do
      result = AppStore.validate_input(strict, "8000", nil, {} of String => String, "/data")
      result.errors.any?(&.includes?("Count")).should be_true
    end

    it "accepts valid values" do
      result = AppStore.validate_input(strict, "8000", nil, {"COUNT" => "3", "CODE" => "abc", "MODE" => "fast"}, "/data")
      result.errors.should be_empty
      result.env["COUNT"].should eq("3")
      result.env["CODE"].should eq("abc")
      result.env["MODE"].should eq("fast")
    end

    it "rejects values failing regex, length or option checks" do
      result = AppStore.validate_input(strict, "8000", nil, {"COUNT" => "x", "CODE" => "ab", "MODE" => "medium"}, "/data")
      result.errors.size.should eq(3)
    end
  end

  describe "env files" do
    it "round-trips values and strips quotes and comments" do
      content = AppStore.env_file_content({"A" => "1", "B" => "two words", "C" => "line\nbreak"})
      parsed = AppStore.parse_env_file(content)
      parsed["A"].should eq("1")
      parsed["B"].should eq("two words")
      parsed["C"].should eq("line break")
    end

    it "ignores comments and malformed lines" do
      parsed = AppStore.parse_env_file("# comment\n\nNOEQUALS\nOK=yes\n")
      parsed.size.should eq(1)
      parsed["OK"].should eq("yes")
    end
  end

  describe ".transform_compose" do
    it "strips x-runtipi, adds the port mapping, restart policy and label substitution" do
      rendered = AppStore.transform_compose(X_RUNTIPI_COMPOSE, "whoami")
      rendered.should_not contain("x-runtipi")
      rendered.should contain("restart: unless-stopped")
      rendered.should contain(%(${APP_PORT}:80))
      rendered.should_not contain("{{RUNTIPI_APP_ID}}")
      rendered.should contain("whoami.rule")
    end

    it "localizes referenced networks so the project stands alone" do
      rendered = AppStore.transform_compose(X_RUNTIPI_COMPOSE, "whoami")
      rendered.should contain("tipi_main_network")
      rendered.should_not contain("external")
    end

    it "leaves legacy compose files (without x-runtipi) structurally alone" do
      rendered = AppStore.transform_compose(LEGACY_COMPOSE, "legacy")
      rendered.should contain(%(${APP_PORT}:8080))
      rendered.should contain("restart: unless-stopped")
    end

    it "raises RenderError for non-mapping documents" do
      expect_raises(AppStore::RenderError) do
        AppStore.transform_compose("- just\n- a\n- list\n", "x")
      end
    end
  end

  describe "the sync + install + update lifecycle" do
    root = File.tempname("grafito-appstore-spec")

    it "syncs a store tarball, unpacking only apps/ files" do
      tarball = build_store_tarball({
        "runtipi-appstore-master/apps/whoami/config.json"        => WHOAMI_CONFIG,
        "runtipi-appstore-master/apps/whoami/docker-compose.yml" => X_RUNTIPI_COMPOSE,
        "runtipi-appstore-master/apps/whoami/metadata/desc.md"   => "long description",
        "runtipi-appstore-master/README.md"                      => "repo readme",
        "runtipi-appstore-master/scripts/build.sh"               => "rm -rf /",
        "runtipi-appstore-master/apps/../../escaped.txt"         => "nope",
      })
      WebMock.stub(:get, "https://stores.example/test.tar.gz")
        .to_return(body_io: tarball, headers: {"Content-Type" => "application/gzip"})

      count = AppStore.sync(TEST_STORE, root, force: true)
      count.should eq(1)
      AppStore.synced?(TEST_STORE, root).should be_true
      AppStore.last_sync(TEST_STORE, root).should_not be_nil
    end

    it "lists and finds apps from the synced store" do
      apps = AppStore.list_apps(TEST_STORE, root)
      apps.size.should eq(1)
      apps[0].id.should eq("whoami")
      fail "whoami app missing" if AppStore.find_app(TEST_STORE, root, "whoami").nil?
      AppStore.find_app(TEST_STORE, root, "../evil").should be_nil
    end

    it "renders an install and discovers it back" do
      app = AppStore.find_app(TEST_STORE, root, "whoami")
      fail "whoami app missing" if app.nil?
      input = AppStore.validate_input(app, "8381", nil, {} of String => String, root)
      installed = AppStore.render_install(TEST_STORE, app, input, root)

      installed.project_name.should eq("whoami")
      File.exists?(installed.compose_file(root)).should be_true
      File.exists?(installed.env_file(root)).should be_true

      discovered = AppStore.find_installed(root, "whoami")
      fail "install record missing" if discovered.nil?
      discovered.project_name.should eq("whoami")
      discovered.port.should eq(8381)
      discovered.store.should eq("test-store")
      AppStore.compose_command(root, installed, "up", "-d").should eq([
        "docker", "compose",
        "--project-name", "whoami",
        "-f", installed.compose_file(root),
        "--env-file", installed.env_file(root),
        "up", "-d",
      ])
    end

    it "prepares an update when the store has a newer package, preserving user env" do
      installed = AppStore.find_installed(root, "whoami")
      fail "install record missing" if installed.nil?
      File.write(installed.env_file(root), "WHOAMI_MESSAGE=custom\nAPP_PORT=8381\n")

      # Same package: nothing to render.
      AppStore.prepare_update(root, installed)[0].should contain("unchanged")

      # Bump the store package.
      newer = WHOAMI_CONFIG.sub(%("tipi_version": 3), %("tipi_version": 4))
        .sub(%("version": "1.10.1"), %("version": "1.11.0"))
      File.write(File.join(AppStore.store_dir(root, "test-store"), "apps", "whoami", "config.json"), newer)

      messages = AppStore.prepare_update(root, installed)
      messages[0].should contain("1.11.0")
      AppStore.parse_env_file(File.read(installed.env_file(root)))["WHOAMI_MESSAGE"].should eq("custom")
      updated = AppStore.find_installed(root, "whoami")
      fail "install record missing" if updated.nil?
      updated.tipi_version.should eq(4)
    end

    it "removes installs (keeping data unless asked)" do
      installed = AppStore.find_installed(root, "whoami")
      fail "install record missing" if installed.nil?
      Dir.mkdir_p(installed.data_dir(root))
      AppStore.remove_install(root, installed, delete_data: false)
      Dir.exists?(installed.install_dir(root)).should be_false
      Dir.exists?(installed.data_dir(root)).should be_true
      AppStore.find_installed(root, "whoami").should be_nil
    end
  end
end
