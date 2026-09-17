require "./spec_helper"

# Pure-logic specs for the update detection; the registry side is
# I/O and exercised only through its parse helpers.
describe ComposeUpdates do
  describe ".parse_registry_info" do
    it "maps Docker Hub library images" do
      host, repo = ComposeUpdates.parse_registry_info("nginx")
      host.should eq("registry-1.docker.io")
      repo.should eq("library/nginx")
    end

    it "maps Docker Hub namespaces" do
      host, repo = ComposeUpdates.parse_registry_info("ralsina/grafito")
      host.should eq("registry-1.docker.io")
      repo.should eq("ralsina/grafito")
    end

    it "detects custom registries by the first path segment" do
      host, repo = ComposeUpdates.parse_registry_info("ghcr.io/ralsina/grafito:latest")
      host.should eq("ghcr.io")
      repo.should eq("ralsina/grafito")

      host, repo = ComposeUpdates.parse_registry_info("registry.example.com:5000/app/web")
      host.should eq("registry.example.com:5000")
      repo.should eq("app/web")
    end

    it "rewrites the lscr.io vanity host" do
      host, repo = ComposeUpdates.parse_registry_info("lscr.io/linuxserver/heimdall")
      host.should eq("ghcr.io")
      repo.should eq("linuxserver/heimdall")
    end
  end

  describe ".image_tag" do
    it "splits tags after the last slash only" do
      ComposeUpdates.image_tag("nginx:1.27").should eq("1.27")
      ComposeUpdates.image_tag("localhost:5000/app:2.0").should eq("2.0")
      ComposeUpdates.image_tag("localhost:5000/app").should eq("latest")
      ComposeUpdates.image_tag("nginx").should eq("latest")
    end
  end

  describe ".update_available?" do
    it "is true when the remote digest is new" do
      local = ["nginx@sha256:aaa", "index.docker.io/library/nginx@sha256:aaa"]
      ComposeUpdates.update_available?(local, "sha256:bbb").should be_true
    end

    it "is false when the digests match, ignoring the sha256: prefix" do
      ComposeUpdates.update_available?(["nginx@sha256:aaa"], "aaa").should be_false
      ComposeUpdates.update_available?(["nginx@aaa"], "sha256:aaa").should be_false
    end

    it "is false without a remote digest" do
      ComposeUpdates.update_available?(["nginx@sha256:aaa"], nil).should be_false
    end
  end

  it "parses demo results without touching docker" do
    {% if flag?(:demo_mode) %}
      a = ComposeUpdates.check_service("webapp/api")
      b = ComposeUpdates.check_service("webapp/api")
      a.update_available?.should eq(b.update_available?)
    {% else %}
      # Real mode: deterministic parse of inspect output instead of a
      # live docker call.
      ComposeUpdates.parse_repo_digests(
        %q(["ghcr.io/ralsina/grafito@sha256:abc", "grafito@sha256:abc"])
      ).size.should eq(2)
    {% end %}
  end
end
