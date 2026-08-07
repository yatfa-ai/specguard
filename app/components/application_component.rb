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
  # Every component consumes the caller's `class:` with a MUTATING `delete`, memoised. That one line
  # bundles two separate properties, and they do NOT hold over the same set of sites. Read the
  # uniformity as a single convention and you will over-trust it.
  #
  # The MEMOISATION is load-bearing at all 19 sites. A mutating read is only safe if it happens
  # exactly once, so every such method is memoised rather than converted to a non-mutating read:
  # memoisation keeps consume-once semantics and makes the method idempotent — call it twice and you
  # get the same string, instead of the caller's class silently vanishing on the second call.
  # De-memoise any of the 19 and its idempotence example goes red.
  #
  # The `delete` is load-bearing at only EIGHT of them — the sites that also splat the remaining
  # options onto the same element: `alert` and `panel` (via `tag.attributes(html_options)`),
  # `badge`, `heading`, `page`, `button`, `card` (via `**@options`), and `Forms::FieldComponent`
  # (via `**@input_options`). There the `delete` is what stops `:class` reaching the element a
  # second time. Switch one of those to `@options[:class]` and it either emits a duplicate `class`
  # attribute (the `tag.attributes` case — which Nokogiri silently drops on parse, so it has to be
  # caught on the raw string) or lets the caller's class override the component's own variant
  # classes outright (the kwargs-splat case, where the last key wins). Both are silent; both are
  # caught.
  #
  # At the other ELEVEN sites `@options` is read exactly once, by this method, and never reaches an
  # element at all. There `delete` versus `[]` is unobservable in the rendered output, and the
  # mutation matrix confirms it: rewriting those to `@options[:class]` leaves the entire render
  # suite green. Keeping `delete` there is CONSISTENCY, not correctness — one construct to
  # recognise, and no per-component judgement call about which category applies. It is NOT evidence
  # that all 19 are guarded against the wrong fix. Only the eight are, and only the eight can be.
  #
  # `spec/support/shared_examples/caller_class.rb` pins both halves for every component that does
  # this; `spec/components/caller_class_consumption_spec.rb` keeps the site list complete.
  def merge_classes(*lists)
    lists.flatten.compact.flat_map { |list| list.to_s.split(/\s+/) }.reject(&:empty?).uniq.join(" ")
  end
end
