# frozen_string_literal: true

# A lighter surface than Panel: no header slot, raised background, same panel-border treatment.
class UI::CardComponent < ApplicationComponent
  def initialize(href: nil, **options)
    @href = href
    @options = options
    super
  end

  def call
    classes = merge_classes(
      "block bg-app-surface-raised border border-app-panel-border rounded-lg shadow-app p-4",
      @href ? "transition-colors hover:border-app-cta" : nil,
      @options.delete(:class)
    )

    if @href
      link_to(@href, class: classes, **@options) { content }
    else
      tag.div(content, class: classes, **@options)
    end
  end
end
