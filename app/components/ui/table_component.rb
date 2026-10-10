# frozen_string_literal: true

# A table. Two modes:
#
#   * plain (the default) — what every other page uses.
#   * `sortable: true` — the console table: sticky header, click a column header to sort, rows that
#     carry `data-href` open the detail drawer. A column is a String, or a Hash
#     `{ label:, end: true, sort: false }` when it is numeric (right aligned) or must not sort.
#
# There is deliberately no scroll wrapper on the console table: a table that scrolls on its own
# inside a scrolling page is a nested scroll container, and it takes `position: sticky` away from
# the header. Long paths wrap (`overflow-wrap: anywhere`) instead; only a narrow viewport scrolls it.
class UI::TableComponent < ApplicationComponent
  def initialize(columns: [], describedby: nil, sortable: false, **options)
    @columns = columns
    @describedby = describedby
    @sortable = sortable
    @options = options
    super
  end

  attr_reader :columns

  def sortable? = @sortable

  def wrapper_class
    @wrapper_class ||= merge_classes(sortable? ? "rc-table-wrap" : "w-full overflow-x-auto", @options.delete(:class))
  end

  def wrapper_attributes
    sortable? ? { data: { controller: "datatable" } } : {}
  end

  def table_attributes
    attributes = { class: sortable? ? "dt" : "w-full text-sm" }
    attributes["aria-describedby"] = @describedby if @describedby.present?
    attributes
  end

  def column_label(column) = column.is_a?(Hash) ? column[:label] : column

  def column_end?(column) = column.is_a?(Hash) && column[:end]

  def column_sortable?(column)
    return false unless sortable?

    column.is_a?(Hash) ? column.fetch(:sort, true) && column[:label].present? : column.present?
  end
end
