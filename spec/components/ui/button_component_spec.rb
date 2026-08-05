# frozen_string_literal: true

require "rails_helper"

RSpec.describe UI::ButtonComponent, type: :component do
  it "captures a block passed to .new — the brace form every call site uses" do
    render_inline(described_class.new(variant: :primary) { "Save" })

    expect(page).to have_css("button", text: "Save")
  end

  it "renders an anchor when href is given, so link-styled-as-button navigation works" do
    render_inline(described_class.new(variant: :ghost, href: "/repositories") { "Cancel" })

    expect(page).to have_css("a[href='/repositories']", text: "Cancel")
  end

  it "derives every variant from app-* tokens, never a raw palette colour" do
    described_class::VARIANTS.each_value do |classes|
      expect(classes).not_to match(/(?:bg|text|border)-(?:gray|slate|red|green|blue|white|black)/)
    end
  end

  it "appends caller classes instead of replacing the variant's" do
    render_inline(described_class.new(variant: :primary, class: "w-full") { "Save" })

    expect(page).to have_css("button.w-full.bg-app-cta")
  end

  it "exposes the same classes to button_to call sites" do
    expect(described_class.classes(variant: :danger, size: :sm, extra: "w-full"))
      .to include("bg-app-error-surface", "text-sm", "w-full")
  end
end
