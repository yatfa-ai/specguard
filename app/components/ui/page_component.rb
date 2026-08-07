# frozen_string_literal: true

# Page body wrapper. Deliberately NO max-width cap — SpecGuard is full-width, like yatfa.
class UI::PageComponent < ApplicationComponent
  def initialize(**options)
    @options = options
    super
  end

  def call
    # Read into a local FIRST: `**@options` lands on the same tag, and `wrapper_class` is what
    # removes `:class` from that hash.
    classes = wrapper_class

    tag.div(content, class: classes, **@options)
  end

  # `delete`, not `[]` — a surviving `:class` in the splat would override this list entirely.
  # Memoised so a second call still carries the caller's class.
  def wrapper_class
    @wrapper_class ||= merge_classes("w-full px-6 py-6 space-y-6", @options.delete(:class))
  end
end
