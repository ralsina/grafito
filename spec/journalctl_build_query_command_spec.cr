require "spec"
require "../src/journalctl"

describe Journalctl do
  describe ".build_query_command" do
    base_command = ["journalctl", "-m", "-o", "json", "-n", "5000", "-r"]

    it "returns the base command when no parameters are provided" do
      command = Journalctl.build_query_command(since: nil, unit: nil, tag: nil, query: nil, priority: nil, hostname: nil)
      command.should eq(base_command)
    end

    it "adds -S flag when 'since' is provided" do
      command = Journalctl.build_query_command(since: "-1h", unit: nil, tag: nil, query: nil, priority: nil, hostname: nil)
      command.should eq(base_command + ["-S", "-1h"])
    end

    it "adds -u flag for each word when 'unit' is provided" do
      command = Journalctl.build_query_command(since: nil, unit: "nginx.service docker.service", tag: nil, query: nil, priority: nil, hostname: nil)
      command.should eq(base_command + ["-u", "nginx.service", "-u", "docker.service"])
    end

    it "strips whitespace from unit words and ignores empty ones" do
      command = Journalctl.build_query_command(since: nil, unit: "  apache  ", tag: nil, query: nil, priority: nil, hostname: nil)
      command.should eq(base_command + ["-u", "apache"])

      command_empty_mid = Journalctl.build_query_command(since: nil, unit: "systemd  networkd", tag: nil, query: nil, priority: nil, hostname: nil)
      command_empty_mid.should eq(base_command + ["-u", "systemd", "-u", "networkd"])
    end

    it "adds -t flag for include tags and -T for exclude tags" do
      command_include = Journalctl.build_query_command(since: nil, unit: nil, tag: "myapp", query: nil, priority: nil, hostname: nil)
      command_include.should eq(base_command + ["-t", "myapp"])

      command_exclude = Journalctl.build_query_command(since: nil, unit: nil, tag: "-kernel", query: nil, priority: nil, hostname: nil)
      command_exclude.should eq(base_command + ["-T", "kernel"])
    end

    it "handles mixed include and exclude tags" do
      command = Journalctl.build_query_command(since: nil, unit: nil, tag: "audit -systemd myapp", query: nil, priority: nil, hostname: nil)
      # Order of -t and -T might vary based on split, but all should be present
      command.should eq(base_command + ["-t", "audit", "-T", "systemd", "-t", "myapp"])
    end

    it "ignores single hyphen tag" do
      command = Journalctl.build_query_command(since: nil, unit: nil, tag: "-foo -", query: nil, priority: nil, hostname: nil)
      # We should not pass bare hyphens
      command.should eq(base_command + ["-T", "foo"])
    end

    it "adds -g flag when 'query' is provided" do
      command = Journalctl.build_query_command(since: nil, unit: nil, tag: nil, query: "error message", priority: nil, hostname: nil)
      command.should eq(base_command + ["-g", "error message"])
    end

    it "adds -p flag when 'priority' is provided" do
      command = Journalctl.build_query_command(since: nil, unit: nil, tag: nil, query: nil, priority: "3", hostname: nil)
      command.should eq(base_command + ["-p", "3"])
    end

    it "builds a command with all parameters provided" do
      command = Journalctl.build_query_command(
        since: "-2d",
        unit: "sshd",
        tag: "authentication -debug",
        query: "failed login",
        priority: "4",
        hostname: "server01"
      )
      expected = base_command + [
        "-S", "-2d",
        "-u", "sshd",
        "-t", "authentication", # Order of tags might vary
        "-T", "debug",
        "-g", "failed login",
        "-p", "4",
        "_HOSTNAME=server01",
      ]
      # Use contain_all because the order of tag flags might not be guaranteed
      command.should eq(expected)
    end

    it "handles nil for all optional parameters gracefully" do
      command = Journalctl.build_query_command(
        since: nil,
        unit: nil,
        tag: nil,
        query: nil,
        priority: nil,
        hostname: nil
      )
      command.should eq(base_command)
    end

    it "handles empty strings for optional parameters gracefully (should be treated as nil by caller or ignored)" do
      # The build_query_command method itself doesn't explicitly convert empty strings to nil.
      # It relies on the caller (e.g., Journalctl.query) to handle this or pass nil.
      # If empty strings are passed, they might result in empty arguments.

      command_empty_since = Journalctl.build_query_command(since: "", unit: nil, tag: nil, query: nil, priority: nil, hostname: nil)
      command_empty_since.should eq(base_command + ["-S", ""]) # journalctl might error with empty -S

      command_empty_unit = Journalctl.build_query_command(since: nil, unit: "", tag: nil, query: nil, priority: nil, hostname: nil)
      command_empty_unit.should eq(base_command) # Empty unit string results in no -u flags

      command_empty_tag = Journalctl.build_query_command(since: nil, unit: nil, tag: "", query: nil, priority: nil, hostname: nil)
      command_empty_tag.should eq(base_command) # Empty tag string results in no tag flags

      command_empty_query = Journalctl.build_query_command(since: nil, unit: nil, tag: nil, query: "", priority: nil, hostname: nil)
      command_empty_query.should eq(base_command + ["-g", ""]) # journalctl might error or treat as no-op

      command_empty_priority = Journalctl.build_query_command(since: nil, unit: nil, tag: nil, query: nil, priority: "", hostname: nil)
      command_empty_priority.should eq(base_command + ["-p", ""]) # journalctl might error

      command_empty_hostname = Journalctl.build_query_command(since: nil, unit: nil, tag: nil, query: nil, priority: nil, hostname: "")
      command_empty_hostname.should eq(base_command) # Empty hostname string results in no _HOSTNAME filter

      command_whitespace_hostname = Journalctl.build_query_command(since: nil, unit: nil, tag: nil, query: nil, priority: nil, hostname: "   ")
      command_whitespace_hostname.should eq(base_command) # Whitespace-only hostname string results in no _HOSTNAME filter
    end
  end
end
