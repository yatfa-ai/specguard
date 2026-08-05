# frozen_string_literal: true

# Base class for every SpecGuard ViewComponent.
#
# Ported verbatim (in behaviour) from yatfa's `ApplicationComponent`. Two things live here and
# both are load-bearing:
#
#   * `merge_classes` — de-duplicated composition of a component's variant classes with the
#     caller's overrides, so `class:` at a call site appends rather than replaces.
#
#   * the initializer-block `render_in` capture — `render UI::ButtonComponent.new(...) { "Save" }`
#     binds the brace-block to `.new`, not to `render`, so without this the block would be lost.
#     The base class stashes it at construction time and re-injects it at render time.
#     DO NOT REMOVE — every view call site depends on the brace form.
class ApplicationComponent < ViewComponent::Base
  def initialize(*, **, &block)
    @__initializer_block = block
    super()
  end

  def render_in(view_context, &block)
    super(view_context, &(block || @__initializer_block))
  end

  private

  # Compose class lists, last-writer-wins on duplicates, nils and blanks dropped.
  def merge_classes(*lists)
    lists.flatten.compact.flat_map { |list| list.to_s.split(/\s+/) }.reject(&:empty?).uniq.join(" ")
  end
end
