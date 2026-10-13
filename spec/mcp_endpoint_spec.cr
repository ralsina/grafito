require "./spec_helper"

# MCP endpoint specs: token gates (real mode), the JSON-RPC handshake,
# tools/list shape and tools/call behavior (demo mode, against the
# fakes). The token is global state; every example restores it.

FORM_JSON = HTTP::Headers{"Content-Type" => "application/json"}

def with_mcp_token(token : String?, &)
  old = Grafito.mcp_token
  begin
    Grafito.mcp_token = token
    yield
  ensure
    Grafito.mcp_token = old
  end
end

def mcp_post(body : String, token : String? = "spec-token")
  headers = FORM_JSON.dup
  headers["Authorization"] = "Bearer #{token}" if token
  dispatch_request("POST", "/mcp", body: body, headers: headers)
end

describe "MCP endpoint" do
  it "is disabled (404) without a token" do
    with_mcp_token(nil) do
      response = mcp_post(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}), token: nil)
      response[:status].should eq(404)
    end
  end

  it "rejects a wrong bearer token (401)" do
    with_mcp_token("spec-token") do
      response = mcp_post(%({"jsonrpc":"2.0","id":1,"method":"tools/list"}), token: "wrong")
      response[:status].should eq(401)
    end
  end

  it "server-info reports the mcp flag" do
    with_mcp_token("spec-token") do
      response = dispatch_request("GET", "/server-info")
      response[:body].should contain(%("mcp":true))
    end
    with_mcp_token(nil) do
      response = dispatch_request("GET", "/server-info")
      response[:body].should contain(%("mcp":false))
    end
  end

  {% if flag?(:demo_mode) %}
    it "handshakes and lists the grafito tools" do
      with_mcp_token("spec-token") do
        response = mcp_post(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}))
        response[:status].should eq(200)
        response[:body].should contain(%("name":"grafito"))

        tools = mcp_post(%({"jsonrpc":"2.0","id":2,"method":"tools/list"}))
        tools[:status].should eq(200)
        names = JSON.parse(tools[:body])["result"]["tools"].as_a.map(&.["name"].as_s)
        names.should contain("query_logs")
        names.should contain("list_stacks")
        names.should contain("stack_action")
        names.should_not contain("tool")
      end
    end

    it "query_logs serves fake journal entries" do
      with_mcp_token("spec-token") do
        response = mcp_post(%({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_logs","arguments":{"lines":3}}}))
        response[:status].should eq(200)
        parsed = JSON.parse(JSON.parse(response[:body])["result"]["content"][0]["text"].as_s)
        parsed["count"].as_i.should be > 0
      end
    end

    it "journalctl_command teaches the exact command" do
      with_mcp_token("spec-token") do
        response = mcp_post(%({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"journalctl_command","arguments":{"unit":"ssh","since":"-1h"}}}))
        result = JSON.parse(response[:body])["result"]["content"][0]["text"].as_s
        result.should contain("journalctl")
        result.should contain("-u ssh")
      end
    end

    it "stack_action runs against the fake world" do
      Grafito.enable_actions = true
      begin
        with_mcp_token("spec-token") do
          response = mcp_post(%({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"stack_action","arguments":{"stack":"webapp","action":"restart"}}}))
          response[:status].should eq(200)
          # The command itself needs a real docker: CI containers don't
          # have one, and the tool surfaces that as a JSON-RPC error —
          # which is exactly the "visibly failed" behavior we want.
          envelope = JSON.parse(response[:body])
          if result = envelope["result"]?
            ran = JSON.parse(result["content"][0]["text"].as_s)["ran"].as_a
            ran.size.should be > 0
            ran[0]["command"].as_s.should contain("docker compose")
          else
            envelope["error"]["message"].as_s.should contain("docker")
          end
          # The fake world still knows the stack either way.
          ComposeStatus.stacks.find(&.name.==("webapp")).should_not be_nil
        end
      ensure
        Grafito.enable_actions = false
        FakeComposeData.reset_demo_state
      end
    end

    it "list_processes filters" do
      with_mcp_token("spec-token") do
        response = mcp_post(%({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_processes","arguments":{"limit":5}}}))
        processes = JSON.parse(JSON.parse(response[:body])["result"]["content"][0]["text"].as_s)["processes"].as_a
        processes.size.should be <= 5
      end
    end
  {% end %}

  {% unless flag?(:demo_mode) %}
    describe "mutation gating" do
      it "action tools refuse without enable-actions (demo builds exempt)" do
        Grafito.enable_actions = false
        Grafito.auth_configured_override = false
        begin
          arguments = {
            "stack"  => JSON::Any.new("webapp"),
            "action" => JSON::Any.new("restart"),
          } of String => JSON::Any
          result = Grafito::Mcp::StackActionTool.new.invoke(arguments)
          result["isError"].as_bool.should be_true
          result["content"][0]["text"].as_s.should contain("Mutations are disabled")
        ensure
          Grafito.auth_configured_override = nil
          Grafito.enable_actions = false
        end
      end
    end
  {% end %}
end
