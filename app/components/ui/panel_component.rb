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

  def wrapper_class
    merge_classes(
      "bg-app-surface border border-app-panel-border rounded-lg shadow-app",
      @options.delete(:class)
    )
  end

  def html_options
    @options
  end
end
