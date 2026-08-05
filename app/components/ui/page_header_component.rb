# frozen_string_literal: true

class UI::PageHeaderComponent < ApplicationComponent
  renders_one :actions

  def initialize(title:, subtitle: nil, **options)
    @title = title
    @subtitle = subtitle
    @options = options
    super
  end

  attr_reader :title, :subtitle

  def wrapper_class
    merge_classes("flex flex-wrap items-start justify-between gap-4", @options.delete(:class))
  end
end
