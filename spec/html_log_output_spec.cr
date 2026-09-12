require "./spec_helper"

def make_entry(
  message : String,
  unit : String = "test-unit.service",
  hostname : String = "test-host",
  cursor : String? = nil,
) : Journalctl::LogEntry
  data = Hash(String, String).new
  data["__CURSOR"] = cursor if cursor
  Journalctl::LogEntry.new(
    timestamp: Time.unix(1700000000),
    message_raw: message,
    raw_priority_val: "3",
    internal_unit_name: unit,
    hostname: hostname,
    data: data,
  )
end

describe "Grafito HTML log output" do
  it "escapes HTML in hostnames and unit names" do
    entry = make_entry("hello", unit: "<script>alert(1)</script>", hostname: %(host "quoted"))
    output = Grafito.html_log_output([entry], nil, nil, nil)

    output.should_not contain("<script>alert(1)</script>")
    output.should_not contain(%(host "quoted"))
  end

  it "escapes the cursor when building the AI explanation button" do
    Grafito.ai_provider = FakeAIProvider.new
    entry = make_entry("boom", cursor: "abc'; alert(1); 'x")
    output = Grafito.html_log_output([entry], nil, nil, nil)

    output.should contain("askAIExplanation(")
    # The cursor must arrive as a JSON-encoded string literal, with the
    # quote escaped rather than able to break out of the JS string.
    output.should_not contain("askAIExplanation('abc'")
    Grafito.ai_provider = nil
  end

  it "does not render the AI button when AI is disabled" do
    Grafito.ai_provider = nil
    entry = make_entry("boom", cursor: "some-cursor")
    output = Grafito.html_log_output([entry], nil, nil, nil)

    output.should_not contain("askAIExplanation")
  end

  it "renders an empty state when there are no entries" do
    output = Grafito.html_log_output([] of Journalctl::LogEntry, nil, nil, nil)
    output.should contain("No log entries found.")
  end

  it "highlights search matches without breaking escaping" do
    entry = make_entry("error <b>important</b> thing")
    output = Grafito.html_log_output([entry], nil, nil, "important")

    output.should contain("<mark>important</mark>")
    output.should_not contain("<b>important</b>")
  end
end

describe "Grafito HTML log output tags column" do
  it "renders the syslog identifier as a clickable tag filter" do
    entry = make_entry("hello")
    entry.data["SYSLOG_IDENTIFIER"] = "my-app"
    output = Grafito.html_log_output([entry], nil, nil, nil)

    output.should contain(">Tags<")
    output.should contain("setTagFilterAndTrigger(")
    output.should contain("my-app")
  end

  it "renders an empty tag cell without a link when the entry has no identifier" do
    entry = make_entry("hello")
    output = Grafito.html_log_output([entry], nil, nil, nil)

    output.should contain(">Tags<")
    output.should_not contain("setTagFilterAndTrigger(")
  end

  it "omits the tags column when show_tag is false" do
    entry = make_entry("hello")
    entry.data["SYSLOG_IDENTIFIER"] = "my-app"
    output = Grafito.html_log_output([entry], nil, nil, nil, show_tag: false)

    output.should_not contain(">Tags<")
    output.should_not contain("setTagFilterAndTrigger(")
  end
end
