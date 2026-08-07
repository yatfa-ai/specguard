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
  #
  # == The `@x ||= merge_classes(..., @options.delete(:class))` convention
  #
  # Every component consumes the caller's `class:` with a MUTATING `delete`, and that mutation is
  # load-bearing: components that also splat the remaining options onto the same element
  # (`**@options`, or `tag.attributes(html_options)`) rely on `:class` having left the hash. Switch
  # a site to `@options[:class]` and it either emits a second `class` attribute on one element
  # (`tag.attributes` case) or lets the caller's class override the component's own variant classes
  # entirely (kwargs-splat case, where the last key wins). Both are silent.
  #
  # A mutating read is only safe if it happens exactly once — so every such method is MEMOISED
  # rather than converted to a non-mutating read. Memoisation keeps consume-once semantics and
  # makes the method idempotent: call it twice and you get the same string, instead of the caller's
  # class silently disappearing on the second call. `spec/support/shared_examples/caller_class.rb`
  # pins both halves for every component that does this.
  def merge_classes(*lists)
    lists.flatten.compact.flat_map { |list| list.to_s.split(/\s+/) }.reject(&:empty?).uniq.join(" ")
  end
end
