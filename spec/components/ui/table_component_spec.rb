# frozen_string_literal: true

require "rails_helper"

RSpec.describe UI::TableComponent, type: :component do
  it "points the table at a caption when one is named" do
    render_inline(described_class.new(columns: ["Commit"], describedby: "recent-runs-basis")) { "" }

    expect(page).to have_css("table[aria-describedby='recent-runs-basis']")
  end

  # The default has to be NO attribute, not an empty one. `aria-describedby=""` is a reference to
  # an element that does not exist: it announces exactly as much as having no attribute at all
  # while looking, in the markup, like every table on the site is captioned. Asserted on the raw
  # markup rather than through a CSS selector, because `[aria-describedby]` and
  # `[aria-describedby='']` are different selectors and a matcher for the first would pass on an
  # empty value — the exact confusion this pins against.
  it "emits no aria-describedby at all when none is named" do
    render_inline(described_class.new(columns: ["Commit"])) { "" }

    expect(page.native.to_html).to include(%(<table class="w-full text-sm">))
    expect(page.native.to_html).not_to include("aria-describedby")
  end

  # `class:` belongs to the wrapper div, and `wrapper_class` consumes it with a `delete` — once,
  # memoised. The seam added for `describedby` must not also read `@options`, or the wrapper's
  # classes get duplicated onto a second element.
  #
  # Asserted on the METHOD, not on rendered markup, and that is the whole point of the example.
  # Memoising `wrapper_class` (SPGD-215) made it idempotent but did NOT move WHEN the delete
  # happens: in the template `wrapper_class` still runs on line 1 and `table_attributes` on line 2,
  # so by the time the table is built `:class` has already left the hash. A `table_attributes` that
  # DID merge `@options[:class]` therefore renders identically, and a markup-level assertion passes
  # on evaluation order alone. Re-verified by mutation after the memoisation landed: merging
  # `@options[:class]` into the table's classes leaves every render-level example green — the whole
  # "a component that appends the caller's class" group included — and turns only this one red.
  it "never reads the caller's :class, independent of which accessor the template calls first" do
    component = described_class.new(columns: ["Commit"], class: "lg:col-span-3")

    expect(component.table_attributes).to eq({ class: "w-full text-sm" })
    expect(component.wrapper_class).to include("lg:col-span-3")
  end

  it "keeps caller classes on the wrapper, not on the table" do
    render_inline(described_class.new(columns: ["Commit"], class: "lg:col-span-3")) { "" }

    expect(page).to have_css("div.overflow-x-auto.lg\\:col-span-3 > table")
    expect(page).to have_no_css("table.lg\\:col-span-3")
  end
end
