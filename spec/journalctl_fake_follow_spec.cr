require "spec"
require "../src/grafito"

# The demo-build stand-in for the SSE live tail. Only exists on
# demo_mode builds, so the whole file is compile-time guarded.
{% if flag?(:demo_mode) %}
  describe "Journalctl.fake_follow_entry" do
    it "returns a fresh entry (timestamp within the last minute)" do
      if entry = Journalctl.fake_follow_entry
        entry.timestamp.should be > (Time.local - 1.minute - 1.second)
      else
        fail "expected a fake entry"
      end
    end

    it "returns an entry for the requested unit" do
      if entry = Journalctl.fake_follow_entry(unit: "nginx.service")
        entry.internal_unit_name.should eq("nginx.service")
      else
        fail "expected a fake entry"
      end
    end

    it "returns an entry at or below the requested priority" do
      if entry = Journalctl.fake_follow_entry(priority: "3")
        if priority_value = entry.priority.to_i?
          priority_value.should be <= 3
        else
          fail "expected a numeric priority"
        end
      else
        fail "expected a fake entry"
      end
    end

    it "returns an entry for the requested hostname" do
      if entry = Journalctl.fake_follow_entry(hostname: "server-alpha")
        entry.hostname.should eq("server-alpha")
      else
        fail "expected a fake entry"
      end
    end

    it "returns nil when the filters cannot be satisfied" do
      Journalctl.fake_follow_entry(query: "xyzzyplugh-no-such-word-42").should be_nil
    end
  end
{% end %}
