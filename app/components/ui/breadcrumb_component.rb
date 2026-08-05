# frozen_string_literal: true

# `items` is an array of { label:, href: } — the last entry is rendered as plain text.
class UI::BreadcrumbComponent < ApplicationComponent
  def initialize(items: [], **options)
    @items = items
    @options = options
    super
  end

  attr_reader :items

  def wrapper_class
    merge_classes("flex items-center gap-2 text-sm text-app-content-secondary", @options.delete(:class))
  end
end
