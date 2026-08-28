# frozen_string_literal: true

require "rails_helper"

RSpec.describe UI::ButtonComponent, type: :component do
  # @intent: { entity: "UI::ButtonComponent", action: "accept block content", behavior: "a brace-form block passed to .new renders as the button text node", layer: "integration" }
  it "captures a block passed to .new — the brace form every call site uses" do
    render_inline(described_class.new(variant: :primary) { "Save" })

    expect(page).to have_css("button", text: "Save")
  end

  # @intent: { entity: "UI::ButtonComponent", action: "render href variant", behavior: "passing href renders an anchor to that href instead of a button element", layer: "integration" }
  it "renders an anchor when href is given, so link-styled-as-button navigation works" do
    render_inline(described_class.new(variant: :ghost, href: "/repositories") { "Cancel" })

    expect(page).to have_css("a[href='/repositories']", text: "Cancel")
  end

  # @intent: { entity: "UI::ButtonComponent", action: "derive variant classes", behavior: "every value in VARIANTS contains only app-* design tokens and no raw palette colour", layer: "unit" }
  it "derives every variant from app-* tokens, never a raw palette colour" do
    described_class::VARIANTS.each_value do |classes|
      expect(classes).not_to match(/(?:bg|text|border)-(?:gray|slate|red|green|blue|white|black)/)
    end
  end

  # @intent: { entity: "UI::ButtonComponent", action: "merge caller class", behavior: "a caller :class is appended alongside the variant class on the same button element", layer: "integration" }
  it "appends caller classes instead of replacing the variant's" do
    render_inline(described_class.new(variant: :primary, class: "w-full") { "Save" })

    expect(page).to have_css("button.w-full.bg-app-cta")
  end

  # @intent: { entity: "UI::ButtonComponent", action: "expose .classes", behavior: "the .classes helper returns variant, size and extra classes together for button_to call sites", layer: "unit" }
  it "exposes the same classes to button_to call sites" do
    expect(described_class.classes(variant: :danger, size: :sm, extra: "w-full"))
      .to include("bg-app-error-surface", "text-sm", "w-full")
  end
end
