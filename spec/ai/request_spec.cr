require "../spec_helper"
require "../../src/ai/request"

describe Grafito::AI::Request do
  describe "PRIORITY_MAP constant" do
    it "maps emergency priority names to 0" do
      Grafito::AI::Request::PRIORITY_MAP["emerg"].should eq("0")
      Grafito::AI::Request::PRIORITY_MAP["emergency"].should eq("0")
    end

    it "maps alert priority name to 1" do
      Grafito::AI::Request::PRIORITY_MAP["alert"].should eq("1")
    end

    it "maps critical priority names to 2" do
      Grafito::AI::Request::PRIORITY_MAP["crit"].should eq("2")
      Grafito::AI::Request::PRIORITY_MAP["critical"].should eq("2")
    end

    it "maps error priority names to 3" do
      Grafito::AI::Request::PRIORITY_MAP["err"].should eq("3")
      Grafito::AI::Request::PRIORITY_MAP["error"].should eq("3")
    end

    it "maps warning priority names to 4" do
      Grafito::AI::Request::PRIORITY_MAP["warning"].should eq("4")
      Grafito::AI::Request::PRIORITY_MAP["warn"].should eq("4")
    end

    it "maps notice priority name to 5" do
      Grafito::AI::Request::PRIORITY_MAP["notice"].should eq("5")
    end

    it "maps info priority name to 6" do
      Grafito::AI::Request::PRIORITY_MAP["info"].should eq("6")
    end

    it "maps debug priority name to 7" do
      Grafito::AI::Request::PRIORITY_MAP["debug"].should eq("7")
    end
  end

  describe "#initialize" do
    it "creates a request with all parameters" do
      request = Grafito::AI::Request.new(
        system_prompt: "You are helpful",
        user_prompt: "Hello",
        max_tokens: 500,
        temperature: 0.5
      )

      request.system_prompt.should eq("You are helpful")
      request.user_prompt.should eq("Hello")
      request.max_tokens.should eq(500)
      request.temperature.should eq(0.5)
    end

    it "uses default values for optional parameters" do
      request = Grafito::AI::Request.new(
        system_prompt: "System",
        user_prompt: "User"
      )

      request.max_tokens.should eq(1024)
      request.temperature.should eq(0.7)
    end
  end

  describe ".for_log_analysis" do
    it "creates a request with log analysis prompt" do
      request = Grafito::AI::Request.for_log_analysis("some log context")

      request.system_prompt.should contain("system log analysis")
      request.user_prompt.should contain("some log context")
      request.max_tokens.should eq(1024)
    end

    it "allows custom prompt" do
      request = Grafito::AI::Request.for_log_analysis(
        "context",
        priority: "3",
        prompt: "Custom question"
      )

      request.user_prompt.should contain("Custom question")
      request.user_prompt.should contain("context")
    end

    it "uses default info prompt when no priority specified" do
      request = Grafito::AI::Request.for_log_analysis("context")

      # Default priority is "6" (info)
      request.user_prompt.should contain("informational message")
    end

    describe "priority-based prompts" do
      it "uses critical prompt for emergency (0)" do
        request = Grafito::AI::Request.for_log_analysis("context", "0")

        request.system_prompt.should contain("CRITICAL")
        request.user_prompt.should contain("CRITICAL")
        request.user_prompt.should contain("RIGHT NOW")
      end

      it "uses critical prompt for alert (1)" do
        request = Grafito::AI::Request.for_log_analysis("context", "1")

        request.system_prompt.should contain("CRITICAL")
      end

      it "uses critical prompt for crit (2)" do
        request = Grafito::AI::Request.for_log_analysis("context", "2")

        request.system_prompt.should contain("CRITICAL")
      end

      it "uses error prompt for err (3)" do
        request = Grafito::AI::Request.for_log_analysis("context", "3")

        request.system_prompt.should contain("errors")
        request.user_prompt.should contain("error")
      end

      it "uses warning prompt for warning (4)" do
        request = Grafito::AI::Request.for_log_analysis("context", "4")

        request.system_prompt.should contain("warnings")
        request.user_prompt.should contain("warning")
      end

      it "uses notice prompt for notice (5)" do
        request = Grafito::AI::Request.for_log_analysis("context", "5")

        request.system_prompt.should contain("notable")
        request.user_prompt.should contain("notice")
      end

      it "uses info prompt for info (6)" do
        request = Grafito::AI::Request.for_log_analysis("context", "6")

        request.system_prompt.should contain("informational")
        request.user_prompt.should contain("informational")
      end

      it "uses debug prompt for debug (7)" do
        request = Grafito::AI::Request.for_log_analysis("context", "7")

        request.system_prompt.should contain("debug")
        request.user_prompt.should contain("debug")
      end

      it "accepts named priority strings" do
        request = Grafito::AI::Request.for_log_analysis("context", "warning")

        request.system_prompt.should contain("warnings")
      end

      it "handles unknown priority gracefully" do
        request = Grafito::AI::Request.for_log_analysis("context", "unknown")

        request.system_prompt.should contain("system log analysis")
        request.user_prompt.should contain("explain this log entry")
      end
    end
  end
end
