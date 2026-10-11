# frozen_string_literal: true

# repositories#show used to open with one "Overview" panel (#overview) that carried the suite figures,
# the run's cost, the shard decomposition, the declared layers and the intent readings. The console
# says the same things, once each, in the section that answers the question: the verdict card
# (#summary) and the notes folded under it, "What changed" (#changes), "What is not annotated"
# (#annotations) and "What is slow" (#slow) — and, for a repository CI has never reported to, the
# onboarding checklist (#getting-started) that stands in for all of them.
#
# Specs that asserted "the Overview says X" now assert "the page's overview-equivalent sections say X":
# this composes exactly those four regions — and nothing else on the page — into one scoped node, so
# a figure printed in an unrelated panel (the Recent runs table, Delivery) still cannot satisfy it.
module ConsoleSections
  OVERVIEW_SELECTORS = ["#summary", ".rc-notes", "#changes", "#annotations", "#slow", "#getting-started"].freeze

  def console_overview(body = response.body)
    doc = Capybara.string(body)
    html = OVERVIEW_SELECTORS.filter_map { |selector| doc.first(selector, minimum: 0)&.native&.to_html }.join("\n")
    raise Capybara::ElementNotFound, "Unable to find the console's overview sections" if html.blank?

    Capybara.string(html)
  end
end

RSpec.configure { |config| config.include ConsoleSections, type: :request }

# A declared-layers cell in the console is a stacked bar with a key — `unit 1`, `request 1`,
# `undeclared 1` as list items — where the old table printed one sentence, `unit 1 · request 1 ·
# undeclared 1`. The key items ARE the sentence's parts (the same counts, in the same order), so a
# spec reads them back joined the way the sentence was, and a cell with no key (a file that
# declared nothing at all) reads as its plain text.
module ConsoleLayerCells
  def layer_cell_text(cell)
    parts = cell.all(".rc-key li").map { |item| item.text.gsub(/\s+/, " ").strip }
    parts.any? ? parts.join(" · ") : cell.text.gsub(/\s+/, " ").strip
  end
end
RSpec.configure { |config| config.include ConsoleLayerCells, type: :request }
