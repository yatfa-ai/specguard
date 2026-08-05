# frozen_string_literal: true

# The 4-step type ramp, as a component. Colour is deliberately not baked in — the heading keeps
# whatever token colour its context gives it.
class UI::HeadingComponent < ApplicationComponent
  RAMP = { 1 => "text-app-h1", 2 => "text-app-h2", 3 => "text-app-h3", 4 => "text-app-h4" }.freeze

  def initialize(level: 2, **options)
    @level = RAMP.key?(level) ? level : 2
    @options = options
    super
  end

  def call
    content_tag("h#{@level}", content,
                class: merge_classes(RAMP.fetch(@level), @options.delete(:class)), **@options)
  end
end
