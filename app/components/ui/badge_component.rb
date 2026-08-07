# frozen_string_literal: true

class UI::BadgeComponent < ApplicationComponent
  BASE = "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold"

  TONES = {
    neutral: "bg-app-neutral-surface text-app-content-secondary",
    success: "bg-app-success-surface text-app-success",
    warning: "bg-app-warning-surface text-app-warning",
    error: "bg-app-error-surface text-app-error",
    info: "bg-app-info-surface text-app-info"
  }.freeze

  def initialize(tone: :neutral, **options)
    @tone = tone
    @options = options
    super
  end

  def call
    # Read into a local FIRST: `**@options` lands on the same tag, and `badge_class` is what
    # removes `:class` from that hash.
    classes = badge_class

    tag.span(content, class: classes, **@options)
  end

  # `delete`, not `[]` — a surviving `:class` in the splat would override this list entirely and
  # the tone would be lost. Memoised so a second call still carries the caller's class.
  def badge_class
    @badge_class ||= merge_classes(BASE, TONES.fetch(@tone, TONES[:neutral]), @options.delete(:class))
  end
end
