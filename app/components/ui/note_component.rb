# frozen_string_literal: true

# The "how to read this" prose that used to sit stacked above every table, folded behind one line.
# The words are the panel's own and are unchanged; only their place moved. `id` is the id the table's
# `aria-describedby` points at, so the description still reaches a screen-reader user whether or not
# the disclosure is open.
class UI::NoteComponent < ApplicationComponent
  def initialize(summary:, id: nil, **options)
    @summary = summary
    @id = id
    @options = options
    super
  end

  attr_reader :summary, :id

  def wrapper_class = @wrapper_class ||= merge_classes("dc-note", @options.delete(:class))
end
