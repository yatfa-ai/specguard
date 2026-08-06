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

  def wrapper_class
    merge_classes("rounded-md border px-4 py-3 text-sm",
                  TONES.fetch(@tone, TONES[:info]), @options.delete(:class))
  end

  def html_options = @options
end
