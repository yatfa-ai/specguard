# frozen_string_literal: true

# Details/summary based — no JS needed, and it closes on Escape for free.
class UI::DropdownComponent < ApplicationComponent
  renders_one :trigger

  def initialize(label: nil, align: :right, **options)
    @label = label
    @align = align
    @options = options
    super
  end

  attr_reader :label

  def menu_class
    @align == :left ? "left-0" : "right-0"
  end

  def wrapper_class
    merge_classes("relative inline-block", @options.delete(:class))
  end
end
