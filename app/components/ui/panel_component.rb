# frozen_string_literal: true

# The primary surface. Note `border-app-panel-border` + `shadow-app`: in dark, `--app-border` is
# byte-identical to `--app-surface-raised`, so a plain 1px border would be invisible. The fix is
# panel-scoped on purpose — do not "fix" the global `--app-border` instead.
class UI::PanelComponent < ApplicationComponent
  renders_one :actions

  def initialize(title: nil, icon: nil, body_class: nil, **options)
    @title = title
    @icon = icon
    @body_class = body_class
    @options = options
    super
  end

  attr_reader :title, :icon, :body_class

  def header?
    @title.present? || actions?
  end

  # `delete`, not `[]`: `html_options` splats whatever is LEFT of `@options` into the same `<div>`
  # this class list is written onto, so leaving `:class` in the hash emits a second `class`
  # attribute on one element. Memoised so the method is idempotent — a mutating read is only safe
  # if you can guarantee it happens exactly once, and this way you no longer have to.
  def wrapper_class
    @wrapper_class ||= merge_classes(
      "bg-app-surface border border-app-panel-border rounded-lg shadow-app",
      @options.delete(:class)
    )
  end

  # Consumes `:class` before handing the rest over, so the guarantee is structural rather than a
  # bet on the template reading `wrapper_class` first.
  def html_options
    wrapper_class
    @options
  end
end
