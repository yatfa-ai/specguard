# frozen_string_literal: true

require "rails_helper"

# `UI::EmptyStateComponent`'s description, which since SPGD-1860 can arrive two ways: the
# `description:` param every one of its call sites passed until now, and a `with_description`
# block. The split is load-bearing, not stylistic — the param renders ESCAPED (the template
# interpolates it as `<%= description %>`), which is right for plain sentences and wrong for the
# degenerate comparison branches whose sentence grew a link naming the previous run by sha. Those
# seven sites pass the sentence as the block, and the component renders it html-safe, captured
# ERB. The rule the ticket set: the block slot, never `.html_safe` on a string.
#
# The examples are written against RENDERED MARKUP, and the escaped case is pinned as the
# negative: a param whose text contains a link renders it escaped (visible `&lt;a` text, no real
# anchor), so a future "simplification" that routed the linked sentences back through the param
# fails here and not only on the console page.
RSpec.describe UI::EmptyStateComponent, type: :component do
  # A raw anchor, so the block case exercises exactly the shape the console sites pass — markup
  # that must survive to the output — without dragging view helpers into the spec's binding (a
  # slot block executes in its capturing binding, where `link_to` is not defined).
  def sha_link = %(<a href="/repositories/acme/service?commit_sha=a1b2c3d4e5f6#summary">a1b2c3d</a>).html_safe

  describe "the description param (the path every pre-existing call site takes)" do
    # @intent: { entity: "UI::EmptyStateComponent", action: "render description param", behavior: "the param string renders as the component's muted paragraph, unchanged from before the block slot existed", layer: "unit" }
    it "renders the param as the muted paragraph" do
      render_inline(described_class.new(title: "No comparison to draw", description: "Nothing to measure."))

      expect(page).to have_css("p", text: "Nothing to measure.")
    end

    # The escaped-markup pin. Interpolated ERB escapes `<a>` into visible text — which is exactly
    # why the linked sentences must NOT travel as the param.
    # @intent: { entity: "UI::EmptyStateComponent", action: "escape description param", behavior: "a param containing link markup renders it escaped as visible text, with no real anchor", layer: "unit" }
    it "renders a link-shaped param ESCAPED, as visible text and not an anchor" do
      render_inline(described_class.new(title: "No comparison to draw",
                                        description: "The previous run (#{sha_link}) reported no tests."))

      expect(page).to have_no_css("p a")
      expect(page).to have_text("The previous run (<a")
    end

    # @intent: { entity: "UI::EmptyStateComponent", action: "omit paragraph", behavior: "with no description at all the component renders no paragraph", layer: "unit" }
    it "renders no paragraph when nothing was passed" do
      render_inline(described_class.new(title: "No comparison to draw"))

      expect(page).to have_no_css("p")
    end
  end

  describe "the with_description block slot (the path the linked sentences take)" do
    # The positive control for the escaped-markup pin above: same sentence shape, block path.
    # Asserted on the ELEMENT (a real `<a>` with its href), never on `.text` — Capybara's text
    # decodes entities, so a text assertion cannot tell rendered markup from escaped markup.
    # @intent: { entity: "UI::EmptyStateComponent", action: "render description block", behavior: "a block description renders its markup live, producing a real anchor whose href and text survive", layer: "unit" }
    it "renders the block's markup LIVE: a real anchor, escaped nowhere" do
      render_inline(described_class.new(title: "No comparison to draw")) do |empty|
        empty.with_description do
          "The previous run (#{sha_link}) reported no tests.".html_safe
        end
      end

      anchor = page.find("p a")
      expect(anchor["href"]).to eq("/repositories/acme/service?commit_sha=a1b2c3d4e5f6#summary")
      expect(anchor.text).to eq("a1b2c3d")
    end

    # One rendered paragraph either way — the block path must not add a second one beside the
    # param path's, and must not drop the muted styling the sentence reads in.
    # @intent: { entity: "UI::EmptyStateComponent", action: "render block in the one paragraph", behavior: "a block description fills the same single muted paragraph the param fills, with no extra paragraph", layer: "unit" }
    it "renders the block into the same single muted paragraph" do
      render_inline(described_class.new(title: "No comparison to draw", description: "Stale text.")) do |empty|
        empty.with_description { "Block text wins.".html_safe }
      end

      paragraphs = page.all("p")
      expect(paragraphs.size).to eq(1)
      expect(paragraphs.first.text).to eq("Block text wins.")
      expect(paragraphs.first[:class]).to include("text-app-content-secondary")
    end

    # @intent: { entity: "UI::EmptyStateComponent", action: "keep action slot", behavior: "a block description and an action render together, each once", layer: "unit" }
    it "keeps the action slot beside a block description" do
      render_inline(described_class.new(title: "No comparison to draw")) do |empty|
        empty.with_description { "No comparison.".html_safe }
        empty.with_action { "Reset".html_safe }
      end

      expect(page).to have_css("p", text: "No comparison.")
      expect(page).to have_text("Reset")
    end
  end
end
