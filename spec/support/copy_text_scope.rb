# frozen_string_literal: true

# Re-deriving which copy source a `copy-text` controller can actually see, the way Stimulus does.
#
# `sourceTarget` is SINGULAR and scope-resolved: `Scope#containsElement` is
# `element.closest(controllerSelector) === this.element`, so a source sitting inside a NESTED
# `data-controller="copy-text"` belongs to that inner controller and is invisible to the outer one.
# All three reveal panels rely on this — the repository's `sgk_` key, the account's `sgu_` key, and
# each row of the bulk registration summary — and each nests a second scope precisely so the token
# stays the outer scope's only payload. What that second scope wraps differs by surface: the two
# single-token panels nest their ready-to-run curl snippet, and the bulk row nests its wire-up
# prompt, which has no curl block of its own.
#
# Asserting on `panel.css(...)` directly would not hold that down: it counts sources the controller
# never sees, so collapsing the nested scope — which is what silently hands auto-copy and Download
# the curl command instead of the token — would leave the count unchanged at one and the example
# green. Re-deriving the scope is what makes the assertion about the payload the controller grabs
# rather than about document order.
module CopyTextScope
  # The sources belonging to `panel`'s OWN controller: every `source` target beneath it whose path
  # back up to the panel crosses no other `copy-text` scope. Takes the Capybara node the example
  # already found the panel with.
  def own_copy_sources(panel)
    root = panel.native

    root.css("[data-copy-text-target='source']").reject do |node|
      node.ancestors.take_while { |ancestor| ancestor != root }
          .any? { |ancestor| ancestor["data-controller"].to_s.split.include?("copy-text") }
    end
  end
end

RSpec.configure do |config|
  config.include CopyTextScope
end
