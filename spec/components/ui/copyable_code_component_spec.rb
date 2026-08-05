# frozen_string_literal: true

require "rails_helper"

RSpec.describe UI::CopyableCodeComponent, type: :component do
  it "renders block content as the bare payload inside the copy source" do
    render_inline(described_class.new { "sgk_abcdef" })

    expect(page).to have_css('code[data-copy-text-target="source"]', text: "sgk_abcdef")
    # The Stimulus controller copies textContent verbatim, so the <code> must hold the payload
    # and nothing else — no label, no icon, no whitespace-separated decoration.
    expect(page.find('code[data-copy-text-target="source"]').text).to eq("sgk_abcdef")
  end

  it "does not declare its own copy-text controller scope" do
    # copy_text_controller.js reads the SINGULAR this.sourceTarget. The scope belongs to the
    # caller's wrapper; nesting one here would silently change which element gets copied.
    render_inline(described_class.new { "payload" })

    expect(page).to have_no_css("[data-controller]")
    expect(page.native.to_html).not_to include("copy-text\"")
  end

  it "pairs the payload with a copy button that has a swappable label target" do
    render_inline(described_class.new { "payload" })

    expect(page).to have_css('button[data-action="copy-text#copy"]')
    expect(page).to have_css('span[data-copy-text-target="label"]', text: "Copy")
  end

  it "appends caller classes to the wrapper instead of replacing them" do
    render_inline(described_class.new(class: "w-full") { "payload" })

    expect(page).to have_css("div.w-full.flex.items-center.gap-2")
  end

  it "leaves hand-escaped template text escaped exactly once" do
    # The curl call site passes literal `&lt;token&gt;` as template text. ERB block content arrives
    # as a SafeBuffer and stays raw; passing it as a component argument would re-escape the `&`
    # and emit `&amp;lt;token&amp;gt;` instead.
    render_inline(described_class.new { %(curl -H "Authorization: Bearer &lt;token&gt;").html_safe })

    expect(page.native.to_html).to include(%(curl -H "Authorization: Bearer &lt;token&gt;"))
    expect(page.native.to_html).not_to include("&amp;lt;")
  end

  it "derives the code surface from app-* tokens, never a raw palette colour" do
    expect(described_class::CODE_CLASSES)
      .not_to match(/(?:bg|text|border)-(?:gray|slate|red|green|blue|white|black)/)
  end
end
