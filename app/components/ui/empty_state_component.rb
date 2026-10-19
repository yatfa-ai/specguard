# frozen_string_literal: true

class UI::EmptyStateComponent < ApplicationComponent
  renders_one :action
  # SPGD-1860: a second way to say the same paragraph. The `description:` param renders ESCAPED
  # (see the template's `<%= description %>`), which is right for the 88 plain-string call sites
  # and wrong for the one kind of sentence that grew a link inside it — the seven degenerate
  # comparison branches that name the previous run by sha. Those pass the sentence as this block
  # instead, so the `<a>` arrives as markup and never as an escaped string or an `.html_safe`.
  renders_one :description

  def initialize(title:, description: nil, **options)
    @title = title
    @description = description
    @options = options
    super
  end

  attr_reader :title

  # The param and the block slot share a name by design, so callers read one thing either way.
  # ViewComponent puts the block slot's getter in `GeneratedSlotMethods` precisely so the
  # component class can shadow it (the module is included into the class); this composition is
  # that override: the block when one was passed, the plain param otherwise. Every pre-existing
  # call site renders byte-identically — no block, no slot, `@description` comes straight back —
  # and a site that passes both gets the block, the richer of the two.
  def description
    description? ? super : @description
  end

  def wrapper_class
    @wrapper_class ||= merge_classes(
      "flex flex-col items-center justify-center gap-3 rounded-card border border-dashed " \
      "border-app-border-strong px-6 py-10 text-center",
      @options.delete(:class)
    )
  end
end
