# frozen_string_literal: true

# A code payload paired with a Copy button.
#
#   <div data-controller="copy-text">
#     <%= render UI::CopyableCodeComponent.new do %>the payload<% end %>
#   </div>
#
# `multiline: true` is for a payload that is a *file* rather than a command — a Gemfile group, a
# workflow step, a JSON body. Two things change and nothing else does: the `<code>` gains
# `whitespace-pre` so the newlines the payload actually contains survive HTML's whitespace
# collapsing, and the Copy button aligns to the top of the block instead of to its vertical centre.
#
# The payload still has to reach the element already laid out — `whitespace-pre` preserves every
# space in the template, so a snippet indented to match the surrounding ERB copies to the clipboard
# with that indentation on every line. Multi-line call sites therefore pass a String built outside
# the template (see `IntegrationGuideHelper`) rather than inline block text.
#
# Two things about this component are load-bearing:
#
#   * **The payload is block content, never an argument.** Call sites pass template text that is
#     already hand-escaped (the curl snippet contains a literal `&lt;token&gt;`). As block content
#     it stays raw template output; routed through an argument ViewComponent would escape the `&`
#     again and emit `&amp;lt;token&amp;gt;`.
#
#   * **It does not declare `data-controller="copy-text"`.** `copy_text_controller.js` reads the
#     SINGULAR `this.sourceTarget`, so the caller opens the controller scope and is responsible for
#     putting exactly one of these inside it. Declaring the controller here would nest a second
#     scope and silently change which element gets copied.
class UI::CopyableCodeComponent < ApplicationComponent
  # The `<code>` element must contain the bare payload and nothing else: the Stimulus controller
  # copies `textContent.trim()` verbatim, so any decoration added here lands on the clipboard.
  CODE_CLASSES = "min-w-0 flex-1 overflow-x-auto rounded-md border border-app-border-light " \
                 "bg-app-surface-raised px-3 py-2 font-mono text-sm text-app-content"

  def initialize(multiline: false, **options)
    @multiline = multiline
    @options = options
    super
  end

  # Memoised for the same reason `wrapper_class` is: `merge_classes` is called once and the result
  # is what the template interpolates, so a second read cannot produce a different list.
  def code_class = @code_class ||= merge_classes(CODE_CLASSES, ("whitespace-pre" if @multiline))

  def wrapper_class
    @wrapper_class ||= merge_classes("flex gap-2", @multiline ? "items-start" : "items-center",
                                     @options.delete(:class))
  end
end
