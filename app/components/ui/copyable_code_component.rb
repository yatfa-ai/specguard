# frozen_string_literal: true

# A one-line code payload paired with a Copy button.
#
#   <div data-controller="copy-text">
#     <%= render UI::CopyableCodeComponent.new do %>the payload<% end %>
#   </div>
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

  def initialize(**options)
    @options = options
    super
  end

  def code_class = CODE_CLASSES

  def wrapper_class = @wrapper_class ||= merge_classes("flex items-center gap-2", @options.delete(:class))
end
