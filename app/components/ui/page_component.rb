# frozen_string_literal: true

# Page body wrapper. Deliberately NO max-width cap — SpecGuard is full-width, like yatfa.
class UI::PageComponent < ApplicationComponent
  def initialize(**options)
    @options = options
    super
  end

  def call
    tag.div(content, class: merge_classes("w-full px-6 py-6 space-y-6", @options.delete(:class)), **@options)
  end
end
