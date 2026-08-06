# frozen_string_literal: true

# A single headline number. Numbers are always `tabular-nums`.
class UI::StatComponent < ApplicationComponent
  def initialize(label:, value:, hint: nil, tone: :default, **options)
    @label = label
    @value = value
    @hint = hint
    @tone = tone
    @options = options
    super
  end

  TONES = {
    default: "text-app-content",
    success: "text-app-success",
    warning: "text-app-warning",
    error: "text-app-error",
    info: "text-app-info"
  }.freeze

  attr_reader :label, :value, :hint

  def value_class = TONES.fetch(@tone, TONES[:default])

  def wrapper_class
    merge_classes("space-y-1", @options.delete(:class))
  end
end
