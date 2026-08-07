# frozen_string_literal: true

# A labelled progress bar.
#
# Pass the real counts (`value: annotated, max: total`), not `(percentage, 100)`: the component
# computes `percent` itself, and the raw counts are what land in `aria-valuenow`/`aria-valuemax`,
# so the accessible markup carries the denominator instead of a bare share. Its one consumer is
# the repository dashboard's suite-coverage block (app/views/repositories/show.html.erb).
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

    # Float bounds, not `0`/`100`: `Comparable#clamp` returns THE BOUND ITSELF when the receiver
    # falls outside the range, so Integer bounds made the clamped branches return an Integer
    # (`100.round(1)` is still Integer) while every other branch returned a Float — one fact
    # rendering as "100%" or "100.0%" depending on which branch produced it, in both the printed
    # text and the bar's inline width. Both bounds matter and each is pinned by its own example in
    # `spec/components/ui/meter_component_spec.rb`; reverting either one alone reintroduces the
    # divergence on that side.
    ((value / max) * 100).clamp(0.0, 100.0).round(1)
  end

  def bar_class = TONES.fetch(@tone, TONES[:cta])

  def wrapper_class = merge_classes("space-y-1", @options.delete(:class))
end
