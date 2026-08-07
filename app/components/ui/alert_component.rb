# frozen_string_literal: true

class UI::AlertComponent < ApplicationComponent
  TONES = {
    success: "bg-app-success-surface border-app-success text-app-success",
    warning: "bg-app-warning-surface border-app-warning text-app-warning",
    error: "bg-app-error-surface border-app-error text-app-error",
    info: "bg-app-info-surface border-app-info text-app-info",
    neutral: "bg-app-neutral-surface border-app-border-light text-app-content-secondary"
  }.freeze

  def initialize(tone: :info, title: nil, **options)
    @tone = tone
    @title = title
    @options = options
    super
  end

  attr_reader :title

  # Memoised, and the `delete` is load-bearing — see `wrapper_class` in `UI::PanelComponent` for
  # the full reasoning. This component splats the REMAINING options into the same `<div>`, so the
  # caller's `:class` has to leave `@options`; memoising is what makes a second call return the
  # same string instead of silently dropping it.
  def wrapper_class
    @wrapper_class ||= merge_classes("rounded-md border px-4 py-3 text-sm",
                                     TONES.fetch(@tone, TONES[:info]), @options.delete(:class))
  end

  # Consumes `:class` before handing the rest over, so the guarantee is structural rather than a
  # bet on the template reading `wrapper_class` first. Reading this accessor ahead of
  # `wrapper_class` would otherwise leave `:class` in the hash and emit it a second time.
  def html_options
    wrapper_class
    @options
  end
end
