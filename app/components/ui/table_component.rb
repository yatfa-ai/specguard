# frozen_string_literal: true

# Thin structural wrapper: `columns` renders the header row, the block renders <tr> bodies.
class UI::TableComponent < ApplicationComponent
  def initialize(columns: [], **options)
    @columns = columns
    @options = options
    super
  end

  attr_reader :columns

  def wrapper_class
    merge_classes("w-full overflow-x-auto", @options.delete(:class))
  end
end
