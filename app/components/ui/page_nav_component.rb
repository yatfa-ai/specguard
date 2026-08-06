# frozen_string_literal: true

# Horizontal in-page navigation. `items` is an array of { label:, href:, current: } hashes.
class UI::PageNavComponent < ApplicationComponent
  def initialize(items: [], **options)
    @items = items
    @options = options
    super
  end

  attr_reader :items

  def item_class(item)
    if item[:current]
      "border-app-cta text-app-content"
    else
      "border-transparent text-app-content-secondary hover:text-app-content hover:border-app-border-light"
    end
  end

  def wrapper_class
    merge_classes("flex items-center gap-6 border-b border-app-border", @options.delete(:class))
  end
end
