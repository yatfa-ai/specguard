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
    # Read into a local FIRST: `**@options` lands on the same tag, and `heading_class` is what
    # removes `:class` from that hash.
    classes = heading_class

    content_tag("h#{@level}", content, class: classes, **@options)
  end

  # `delete`, not `[]` — a surviving `:class` in the splat would override this list entirely and
  # the ramp step would be lost. Memoised so a second call still carries the caller's class.
  def heading_class
    @heading_class ||= merge_classes(RAMP.fetch(@level), @options.delete(:class))
  end
end
