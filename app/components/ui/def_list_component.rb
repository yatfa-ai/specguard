# frozen_string_literal: true

# Key/value pairs. `rows` is an array of [term, description] tuples.
class UI::DefListComponent < ApplicationComponent
  def initialize(rows: [], **options)
    @rows = rows
    @options = options
    super
  end

  attr_reader :rows

  def wrapper_class
    @wrapper_class ||= merge_classes("divide-y divide-app-border", @options.delete(:class))
  end
end
