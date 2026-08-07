# frozen_string_literal: true

require "rails_helper"

# `#percent` is the Overview panel's SECOND, independent computation of the headline "annotated %".
# The panel renders that one share twice, from two separate code paths:
#
#   * `show.html.erb:277` -> `TestRun#annotated_ratio` — `(annotated / total * 100).round(1)`,
#     guarded by `total_specs_count.to_i.zero?`, pinned by `spec/models/test_run_spec.rb`.
#   * `show.html.erb:234` -> this component — `((value / max) * 100).clamp(0, 100).round(1)`,
#     guarded by `max <= 0`, handed the RAW COUNTS rather than the ratio (deliberately, see the
#     comment at the call site) so it recomputes the share itself.
#
# Only the model side was pinned. A rounding or formatting change to `percent` alone makes the
# panel visibly contradict itself — two different percentages for one fact, side by side — with
# the whole suite still green. These examples close that half.
#
# No DB records: `TestRun.new` computes `annotated_ratio` off unsaved attributes, and the
# component needs no persistence at all.
RSpec.describe UI::MeterComponent, type: :component do
  describe "#percent" do
    # Asserted against `TestRun#annotated_ratio`'s OWN OUTPUT, not only against literals: the
    # claim is that the two computations agree, and a literal on each side would let them drift
    # apart in lockstep with the spec. The literals ride along as an anchor so the pair cannot
    # agree on a number that is simply wrong.
    #
    # 2/3 is the case the panel actually renders in `repositories_spec.rb`; 2/7 and 1/3 are where
    # 1-decimal rounding bites (28.571 -> 28.6 rounds UP, so truncation would read 28.5).
    {
      [2, 3] => 66.7,
      [3, 3] => 100.0,
      [2, 7] => 28.6,
      [1, 3] => 33.3
    }.each do |(annotated, total), expected|
      it "computes #{annotated}/#{total} as #{expected}, the same share TestRun#annotated_ratio reports" do
        from_the_model = TestRun.new(total_specs_count: total, annotated_specs_count: annotated).annotated_ratio

        expect(described_class.new(value: annotated, max: total).percent).to eq(from_the_model)
        expect(described_class.new(value: annotated, max: total).percent).to eq(expected)
      end
    end

    # The guard is what stands between the panel and `NaN%`/`Infinity%` in a width attribute:
    # without it `0/0` is NaN and `5/0` is Infinity, since the initializer has already coerced
    # both operands with `.to_f`. Asserting `be_a(Float)` and `be_finite` rather than only
    # `eq(0.0)` because `NaN == 0.0` is false but so is `NaN == NaN` — an example that only
    # compared values would report a confusing failure instead of the real one. This mirrors how
    # `test_run_spec.rb:27-28` pins the twin guard on the model side.
    [[0, 0], [5, 0], [5, -4]].each do |(value, max)|
      it "returns a finite 0.0 rather than NaN/Infinity when max is #{max} (value #{value})" do
        percent = described_class.new(value: value, max: max).percent

        expect(percent).to be_a(Float)
        expect(percent).to be_finite
        expect(percent).to eq(0.0)
      end
    end

    # `annotated <= total` holds by construction today (`Ingest::Payload` derives both counts from
    # the same `specs[]`), and nothing in the schema enforces it — `schema.rb` stores two plain
    # integers. The ceiling is the component's stated contract for the day a second consumer
    # arrives without the call site's `suite_size_measured?` gate, and it is load-bearing exactly
    # because nothing fails when someone deletes it as dead code.
    it "holds the 100 ceiling when value exceeds max instead of overflowing the bar" do
      expect(described_class.new(value: 5, max: 3).percent).to eq(100)
    end
  end

  describe "rendered markup" do
    # `percent` reaches the page through TWO separate interpolations — the bar's inline width and
    # the printed text — and they are gated differently: the width always renders, the text only
    # when `label:` is present. Asserting one would leave the other free to drift, which is the
    # same two-spellings-of-one-fact hazard this whole file exists for, one layer down.
    it "carries the same percent into both the bar width and the printed text" do
      render_inline(described_class.new(value: 2, max: 3, label: "Annotated"))

      expect(page).to have_css("[role='meter'] > div[style='width: 66.7%']")
      expect(page).to have_text("66.7%")
    end

    # The bar is the component's whole reason to exist, so the no-label case must still render it
    # at the right width. Without that first assertion the "no percentage text" claim would pass
    # just as well on a component that rendered nothing at all.
    it "renders the bar but no percentage text when no label is passed" do
      render_inline(described_class.new(value: 2, max: 3))

      expect(page).to have_css("[role='meter'] > div[style='width: 66.7%']")
      expect(page).to have_no_text("66.7%")
      expect(page).to have_no_css("span.tabular-nums")
    end
  end

  describe "#bar_class" do
    # Asserted THROUGH THE RENDER, on the bar element's whole class attribute, and against
    # LITERAL class names rather than `TONES[tone]`.
    #
    # Both halves are load-bearing, and each was confirmed by a mutation the other one misses:
    #
    #   * Through the render, because `bar_class` IS `TONES.fetch(...)` — comparing its return
    #     value to `TONES[tone]` restates the method's definition, and stays green when the
    #     template drops `<%= bar_class %>` and ships an invisible bar against its own track.
    #   * Against literals, because interpolating `TONES[tone]` into the expectation puts the
    #     same frozen hash on both sides one layer further out: editing a TONES value to a class
    #     that does not exist moves expectation and actual together and the full suite stays
    #     green. Verified — `cta: "bg-app-cta"` -> `"bg-app-WRONG"` left 677 examples passing
    #     with the render-based-but-interpolated form. Only the literal goes red.
    #
    # `eq` on the full attribute rather than `include`/`have_css`, matching the reasoning already
    # used for `CODE_CLASSES`: `include` passes when an EXTRA tone class is also applied, so only
    # equality catches "the class was dropped" as well as "a second tone was painted over it".
    expected_tone_classes = {
      cta: "bg-app-cta",
      success: "bg-app-success",
      warning: "bg-app-warning",
      error: "bg-app-error",
      info: "bg-app-info"
    }.freeze

    # The literals above are only a contract while they cover the whole enum. Without this, a
    # sixth tone added to TONES renders untested and the loop below silently keeps passing.
    it "states an expected class for every tone the component defines" do
      expect(expected_tone_classes.keys).to match_array(UI::MeterComponent::TONES.keys)
    end

    expected_tone_classes.each do |tone, expected_class|
      it "paints the bar element with #{expected_class} for the #{tone} tone" do
        render_inline(described_class.new(value: 1, max: 2, tone: tone))

        expect(page.find("[role='meter'] > div")[:class]).to eq("h-full rounded-full #{expected_class}")
      end
    end

    # `TONES.fetch(@tone, TONES[:cta])` — the default argument is the whole example. A `fetch`
    # without one raises `KeyError`, so this branch is the difference between a mistyped `tone:`
    # rendering in the wrong colour and the repository dashboard 500ing. Taken through the render
    # too: the fallback's job is to put a real colour on the element, not merely to return a
    # string, and `render_inline` raising is itself the KeyError half of the claim.
    it "falls back to the cta tone on the element rather than raising when the tone is unknown" do
      render_inline(described_class.new(value: 1, max: 2, tone: :chartreuse))

      expect(page.find("[role='meter'] > div")[:class]).to eq("h-full rounded-full bg-app-cta")
    end
  end

  describe "#wrapper_class" do
    # Called directly, and since SPGD-215 memoised it that is no longer a workaround: the method is
    # idempotent, so reading it costs the render nothing. (The comment that used to sit here said
    # the markup depended on evaluation order. It never did for this component — the template calls
    # `wrapper_class` once and splats nothing — and the memoisation settles the general case.)
    #
    # These two survive alongside the render-level coverage in the "a component that appends the
    # caller's class" shared example because they assert something it does not: that group checks
    # the caller's class is PRESENT on the root element, while these pin the exact composed string
    # — the component's own class first, the caller's appended, and the base alone when the caller
    # passes nothing.
    it "appends the caller's class to its own rather than replacing it" do
      component = described_class.new(value: 1, max: 2, class: "lg:col-span-3")

      expect(component.wrapper_class).to eq("space-y-1 lg:col-span-3")
    end

    it "returns its own base class when the caller passes none" do
      expect(described_class.new(value: 1, max: 2).wrapper_class).to eq("space-y-1")
    end
  end
end
