# frozen_string_literal: true

# A labelled progress bar (used by the dashboard's annotated-ratio surface in Phase 4).
class UI::MeterComponent < ApplicationComponent
  TONES = {
    cta: "bg-app-cta",
    success: "bg-app-success",
    warning: "bg-app-warning",
    error: "bg-app-error",
    info: "bg-app-info"
  }.freeze

  def initialize(value:, max: 100, label: nil, tone: :cta, **options)
    @value = value.to_f
    @max = max.to_f
    @label = label
    @tone = tone
    @options = options
    super
  end

  attr_reader :label, :value, :max

  def percent
    return 0.0 if max <= 0

    ((value / max) * 100).clamp(0, 100).round(1)
  end

  def bar_class = TONES.fetch(@tone, TONES[:cta])

  def wrapper_class = merge_classes("space-y-1", @options.delete(:class))
end
