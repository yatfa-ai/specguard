# frozen_string_literal: true

# Re-deriving which copy source a `copy-text` controller can actually see, the way Stimulus does.
#
# `sourceTarget` is SINGULAR and scope-resolved: `Scope#containsElement` is
# `element.closest(controllerSelector) === this.element`, so a source sitting inside a NESTED
# `data-controller="copy-text"` belongs to that inner controller and is invisible to the outer one.
# Both reveal panels rely on this — each nests a second scope around its ready-to-run curl snippet
# precisely so the token stays the outer scope's only payload.
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
