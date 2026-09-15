require "./spec_helper"
require "../src/assets"

# The baked llms.txt should satisfy the recommendations Lighthouse's
# agentic-browsing audit checks: an H1 header, at least one Markdown
# link, and non-trivial content (see llmstxt.org).
describe "baked llms.txt" do
  it "is baked into the binary" do
    Assets.get?("/llms.txt").should_not be_nil
  end

  it "follows the llms.txt recommendations" do
    file = Assets.get?("/llms.txt")
    if file.nil?
      fail "llms.txt is not baked into the binary"
    end
    content = file.gets_to_end

    content.size.should be >= 50
    content.should match(/^\s*#\s+.+/m)
    content.should match(/\[.+\]\(.+\)/)
  end
end
