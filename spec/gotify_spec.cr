require "./spec_helper"

# Gotify specs use webmock for the HTTP client and explicit env var
# manipulation for the config module.
describe Grafito::Gotify do
  around_each do |block|
    # Isolate env var manipulation per spec.
    old_url = ENV["GRAFITO_GOTIFY_URL"]?
    old_token = ENV["GRAFITO_GOTIFY_TOKEN"]?
    block.run
    WebMock.reset
    if old_url
      ENV["GRAFITO_GOTIFY_URL"] = old_url
    else
      ENV.delete("GRAFITO_GOTIFY_URL")
    end
    if old_token
      ENV["GRAFITO_GOTIFY_TOKEN"] = old_token
    else
      ENV.delete("GRAFITO_GOTIFY_TOKEN")
    end
  end

  describe Grafito::Gotify::Config do
    it "is disabled without configuration" do
      ENV.delete("GRAFITO_GOTIFY_URL")
      ENV.delete("GRAFITO_GOTIFY_TOKEN")
      Grafito::Gotify::Config.enabled?.should be_false
    end

    it "is enabled with url and token" do
      ENV["GRAFITO_GOTIFY_URL"] = "https://push.example.com/"
      ENV["GRAFITO_GOTIFY_TOKEN"] = "secret"
      Grafito::Gotify::Config.enabled?.should be_true
      Grafito::Gotify::Config.url.should eq("https://push.example.com")
    end
  end

  describe Grafito::Gotify::Client do
    it "posts the notification to the message endpoint" do
      ENV["GRAFITO_GOTIFY_URL"] = "https://push.example.com"
      ENV["GRAFITO_GOTIFY_TOKEN"] = "secret"

      WebMock.stub(:post, "https://push.example.com/message?token=secret")
        .to_return(status: 200, body: "{\"id\":1}")

      client = Grafito::Gotify::Client.new
      client.send_notification("Title", "Body").should be_true
    end

    it "reports failure when the server rejects the notification" do
      ENV["GRAFITO_GOTIFY_URL"] = "https://push.example.com"
      ENV["GRAFITO_GOTIFY_TOKEN"] = "secret"

      WebMock.stub(:post, "https://push.example.com/message?token=secret")
        .to_return(status: 403, body: "")

      client = Grafito::Gotify::Client.new
      client.send_notification("Title", "Body").should be_false
    end
  end

  describe Grafito::Gotify::Rules do
    now = Time.utc

    it "fires the unit-failed rule" do
      rules = Grafito::Gotify::Rules.new
      alerts = rules.evaluate(disk_used_pct: 10.0, failed_units: ["foo.service"], errors_per_min: 0.0, now: now)
      alerts.map(&.rule).should eq(["unit_failed"])
      alerts.first.message.should contain("foo.service")
    end

    it "fires the disk rule over the threshold" do
      rules = Grafito::Gotify::Rules.new(disk_threshold_pct: 90.0)
      alerts = rules.evaluate(disk_used_pct: 91.0, failed_units: [] of String, errors_per_min: 0.0, now: now)
      alerts.map(&.rule).should eq(["disk_full"])
    end

    it "does not fire the disk rule under the threshold" do
      rules = Grafito::Gotify::Rules.new(disk_threshold_pct: 90.0)
      rules.evaluate(disk_used_pct: 50.0, failed_units: [] of String, errors_per_min: 0.0, now: now).should be_empty
    end

    it "fires the error-rate rule at or over the threshold" do
      rules = Grafito::Gotify::Rules.new(errors_per_min_threshold: 10.0)
      alerts = rules.evaluate(disk_used_pct: 0.0, failed_units: [] of String, errors_per_min: 10.0, now: now)
      alerts.map(&.rule).should eq(["error_rate"])
    end

    it "debounces repeated firings and recovers after the window" do
      rules = Grafito::Gotify::Rules.new
      first = rules.evaluate(disk_used_pct: 95.0, failed_units: [] of String, errors_per_min: 0.0, now: now)
      first.map(&.rule).should eq(["disk_full"])

      # Same condition five minutes later: still within the debounce window.
      repeat = rules.evaluate(disk_used_pct: 95.0, failed_units: [] of String, errors_per_min: 0.0, now: now + 5.minutes)
      repeat.should be_empty

      # After the debounce window the rule may fire again.
      later = rules.evaluate(disk_used_pct: 95.0, failed_units: [] of String, errors_per_min: 0.0, now: now + 11.minutes)
      later.map(&.rule).should eq(["disk_full"])
    end
  end
end
