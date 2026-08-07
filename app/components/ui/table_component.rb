# frozen_string_literal: true

# Thin structural wrapper: `columns` renders the header row, the block renders <tr> bodies.
#
# `describedby` is a NAMED seam, not a general attribute splat, and that is a deliberate choice.
# A splat would have to decide what `class:` means — this component renders TWO elements, and
# `class:` already belongs to the wrapper div via `wrapper_class`, which consumes it with a
# mutating `delete`. Routing everything else to `<table>` while silently holding one key back is
# a rule a caller cannot see from the call site, and getting it wrong duplicates the wrapper's
# classes onto the table. One named keyword for the one association a caller actually needs costs
# a line and has no such ambiguity; widen it when a second attribute genuinely needs the seam.
class UI::TableComponent < ApplicationComponent
  # `describedby`: the id of an element that states what the table's rows ARE — a precondition for
  # reading them, not a note about them. A sighted reader meets such a caption on the way down the
  # page; a screen-reader user landing on the table by navigation does not, and gets the header row
  # with none of it. `aria-describedby` is what carries the caption to that second reader.
  def initialize(columns: [], describedby: nil, **options)
    @columns = columns
    @describedby = describedby
    @options = options
    super
  end

  attr_reader :columns

  def wrapper_class
    @wrapper_class ||= merge_classes("w-full overflow-x-auto", @options.delete(:class))
  end

  # Built as one attribute hash rather than by appending a conditional string, so an unset
  # `describedby` emits NO attribute — not `aria-describedby=""`, which points at an element that
  # does not exist and is its own defect. The two call sites that pass nothing render exactly the
  # bytes they rendered before.
  def table_attributes
    attributes = { class: "w-full text-sm" }
    attributes["aria-describedby"] = @describedby if @describedby.present?
    attributes
  end
end
