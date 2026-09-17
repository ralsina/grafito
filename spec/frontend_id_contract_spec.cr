require "./spec_helper"

# Regression guard for #64 ("Frontend modules share one global
# scope; no JS lint or tests"). There is no JS runtime in this test
# suite, so this doesn't execute the frontend — it statically checks
# that every DOM id looked up with `document.getElementById(...)` in
# the JS modules is actually produced somewhere the browser will see
# it before that lookup runs:
#
#   * a literal `id="..."` in the served HTML shell
#     (src/assets/index.html),
#   * an `id: "..."` attribute from an html_builder view fragment
#     (src/*.cr), or
#   * an id the JS itself creates at runtime (`element.id = "..."`
#     or `setAttribute("id", "...")`).
#
# It catches the class of bug the issue called out: a helper renamed
# or removed on one side (Crystal view or JS module) while the other
# side still references the old id.
describe "frontend id contract" do
  it "defines every DOM id the JS modules look up" do
    js_files = Dir.glob("src/assets/js/*.js")

    referenced_ids = Set(String).new
    js_files.each do |file|
      File.read(file).scan(/getElementById\(\s*["']([a-zA-Z0-9_-]+)["']\s*\)/) do |match|
        referenced_ids << match[1]
      end
    end

    defined_ids = Set(String).new

    File.read("src/assets/index.html").scan(/\bid=["']([a-zA-Z0-9_-]+)["']/) do |match|
      defined_ids << match[1]
    end

    Dir.glob("src/*.cr").each do |file|
      File.read(file).scan(/\bid:\s*["']([a-zA-Z0-9_-]+)["']/) do |match|
        defined_ids << match[1]
      end
    end

    js_files.each do |file|
      content = File.read(file)
      content.scan(/\.id\s*=\s*["']([a-zA-Z0-9_-]+)["']/) { |match| defined_ids << match[1] }
      content.scan(/setAttribute\(\s*["']id["']\s*,\s*["']([a-zA-Z0-9_-]+)["']\s*\)/) { |match| defined_ids << match[1] }
    end

    missing = referenced_ids.to_a.reject { |id| defined_ids.includes?(id) }.sort
    missing.should eq([] of String)
  end
end
