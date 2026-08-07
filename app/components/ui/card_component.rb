# frozen_string_literal: true

# A lighter surface than Panel: no header slot, raised background, same panel-border treatment.
class UI::CardComponent < ApplicationComponent
  def initialize(href: nil, **options)
    @href = href
    @options = options
    super
  end

  def call
    # Read into a local FIRST: both branches splat the remaining `@options` into the same tag, and
    # `wrapper_class` is what removes `:class` from that hash.
    classes = wrapper_class

    if @href
      link_to(@href, class: classes, **@options) { content }
    else
      tag.div(content, class: classes, **@options)
    end
  end

  # `delete`, not `[]` — `**@options` lands on the same element, so a surviving `:class` would
  # override this whole list (last key wins in a kwargs splat). Memoised so calling it twice
  # returns the same string rather than dropping the caller's class on the second call.
  def wrapper_class
    @wrapper_class ||= merge_classes(
      "block bg-app-surface-raised border border-app-panel-border rounded-lg shadow-app p-4",
      @href ? "transition-colors hover:border-app-cta" : nil,
      @options.delete(:class)
    )
  end
end
