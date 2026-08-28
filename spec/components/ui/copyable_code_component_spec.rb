# frozen_string_literal: true

require "rails_helper"

RSpec.describe UI::CopyableCodeComponent, type: :component do
  # @intent: { entity: "UI::CopyableCodeComponent", action: "render payload", behavior: "block content appears as the exact bare textContent of the copy source code element", layer: "integration" }
  it "renders block content as the bare payload inside the copy source" do
    render_inline(described_class.new { "sgk_abcdef" })

    expect(page).to have_css('code[data-copy-text-target="source"]', text: "sgk_abcdef")
    # The Stimulus controller copies textContent verbatim, so the <code> must hold the payload
    # and nothing else — no label, no icon, no whitespace-separated decoration.
    expect(page.find('code[data-copy-text-target="source"]').text).to eq("sgk_abcdef")
  end

  # @intent: { entity: "UI::CopyableCodeComponent", action: "declare controller scope", behavior: "rendered markup carries no data-controller scope so the caller owns the copy-text target", layer: "integration" }
  it "does not declare its own copy-text controller scope" do
    # copy_text_controller.js reads the SINGULAR this.sourceTarget. The scope belongs to the
    # caller's wrapper; nesting one here would silently change which element gets copied.
    render_inline(described_class.new { "payload" })

    expect(page).to have_no_css("[data-controller]")
    expect(page.native.to_html).not_to include("copy-text\"")
  end

  # @intent: { entity: "UI::CopyableCodeComponent", action: "render copy button", behavior: "a button wired to copy-text#copy sits beside the payload with a swappable label target", layer: "integration" }
  it "pairs the payload with a copy button that has a swappable label target" do
    render_inline(described_class.new { "payload" })

    expect(page).to have_css('button[data-action="copy-text#copy"]')
    expect(page).to have_css('span[data-copy-text-target="label"]', text: "Copy")
  end

  # @intent: { entity: "UI::CopyableCodeComponent", action: "merge caller class", behavior: "a caller :class is appended to the wrapper layout classes rather than replacing them", layer: "integration" }
  it "appends caller classes to the wrapper instead of replacing them" do
    render_inline(described_class.new(class: "w-full") { "payload" })

    expect(page).to have_css("div.w-full.flex.items-center.gap-2")
  end

  # @intent: { entity: "UI::CopyableCodeComponent", action: "escape template text", behavior: "hand-escaped SafeBuffer content passes through with the entity escaped exactly once", layer: "integration" }
  it "leaves hand-escaped template text escaped exactly once" do
    # The curl call site passes literal `&lt;token&gt;` as template text. ERB block content arrives
    # as a SafeBuffer and stays raw; passing it as a component argument would re-escape the `&`
    # and emit `&amp;lt;token&amp;gt;` instead.
    render_inline(described_class.new { %(curl -H "Authorization: Bearer &lt;token&gt;").html_safe })

    expect(page.native.to_html).to include(%(curl -H "Authorization: Bearer &lt;token&gt;"))
    expect(page.native.to_html).not_to include("&amp;lt;")
  end

  # @intent: { entity: "UI::CopyableCodeComponent", action: "apply code surface", behavior: "the copy source class attribute equals the CODE_CLASSES constant exactly, pinning definition to render", layer: "integration" }
  it "applies the design-system code surface to the copy source" do
    # `eq`, not `include`: this pins the rendered attribute to the single definition, so the
    # constant and the template cannot drift apart in either direction. Consolidating the class
    # string into one place is only safe if something checks that the one place is wired to the
    # render. (Raw-palette colours are `lint:design_system`'s rule — `SCAN_GLOBS` already covers
    # `app/components/**/*.rb` — so this does not restate it.)
    render_inline(described_class.new { "payload" })

    expect(page.find('code[data-copy-text-target="source"]')[:class])
      .to eq(described_class::CODE_CLASSES)
  end
end
