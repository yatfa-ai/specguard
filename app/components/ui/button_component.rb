# frozen_string_literal: true

# The only sanctioned button in SpecGuard. Raw DaisyUI `btn`/`btn-*` is forbidden (drift lint
# rule `raw_btn`); every variant is derived from `app-*` tokens, so both themes work for free.
#
#   <%= render UI::ButtonComponent.new(variant: :primary) { "Save" } %>
#   <%= render UI::ButtonComponent.new(variant: :ghost, href: repositories_path) { "Cancel" } %>
#
# `button_to` emits its own <button> and cannot nest one — use the class method there:
#
#   <%= button_to "Revoke", path, class: UI::ButtonComponent.classes(variant: :danger, size: :sm) %>
class UI::ButtonComponent < ApplicationComponent
  BASE = "inline-flex items-center justify-center gap-2 rounded-md font-semibold " \
         "transition-colors disabled:opacity-50 disabled:cursor-not-allowed cursor-pointer"

  VARIANTS = {
    primary: "bg-app-cta text-app-background hover:bg-app-cta-hover",
    secondary: "bg-app-surface-raised text-app-content border border-app-border-light hover:bg-app-secondary",
    warning: "bg-app-warning-surface text-app-warning border border-app-warning hover:bg-app-warning hover:text-app-background",
    ghost: "bg-transparent text-app-content-secondary hover:bg-app-neutral-surface hover:text-app-content",
    danger: "bg-app-error-surface text-app-error border border-app-error hover:bg-app-error hover:text-app-background"
  }.freeze

  SIZES = {
    xs: "text-xs px-2 py-1",
    sm: "text-sm px-3 py-1.5",
    md: "text-sm px-4 py-2",
    lg: "text-base px-5 py-2.5"
  }.freeze

  # Shared by the component and by `button_to` call sites.
  def self.classes(variant: :primary, size: :md, extra: nil)
    [BASE, VARIANTS.fetch(variant, VARIANTS[:primary]), SIZES.fetch(size, SIZES[:md]), extra]
      .compact.join(" ")
  end

  def initialize(variant: :primary, size: :md, href: nil, type: "submit", **options)
    @variant = variant
    @size = size
    @href = href
    @type = type
    @options = options
    super
  end

  def call
    # Read into a local FIRST: both branches splat the remaining `@options` into the same tag, and
    # `button_class` is what removes `:class` from that hash.
    classes = button_class

    if @href
      link_to(@href, class: classes, **@options) { content }
    else
      tag.button(type: @type, class: classes, **@options) { content }
    end
  end

  # `delete`, not `[]` — `**@options` lands on the same element, so a surviving `:class` would
  # override this whole list (last key wins in a kwargs splat) and the variant would vanish.
  # Memoised so calling it twice returns the same string rather than dropping the caller's class.
  def button_class
    @button_class ||=
      merge_classes(self.class.classes(variant: @variant, size: @size), @options.delete(:class))
  end
end
