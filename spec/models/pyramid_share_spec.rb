# frozen_string_literal: true

require "rails_helper"

# The ONE expression of the request+system share. `PyramidShare` reads no run attribute and issues
# no query — it is arithmetic over a `layer_counts` hash already in memory — so plain hashes stand
# in for runs here. What is pinned: the values themselves (the four fixture mixes the grid card's
# request-spec pins are cut from, plus every nil branch), the operands the sentence prints, and —
# the extraction's own point — that `RepositoryNarrowing#pyramid_share`, the ordering's reader,
# answers `PyramidShare.of` verbatim on every branch, so the sort and the card's sentence cannot
# drift about which layers are the top of the pyramid or when a mix has nothing declared to take a
# share of.
RSpec.describe PyramidShare do
  # alpha 40% (6 unit + 4 request), bravo a measured 0% (10 unit), foxtrot 33.3% (all four
  # declared layers), golf 25% (3 unit + 1 request), charlie all undeclared — the same five
  # `pyramid_fixture` mixes the repositories grid spec pins the rendered sentences against.
  let(:alpha) { { unit: 6, integration: 0, request: 4, system: 0, undeclared: 0 } }
  let(:bravo) { { unit: 10, integration: 0, request: 0, system: 0, undeclared: 0 } }
  let(:foxtrot) { { unit: 2, integration: 2, request: 1, system: 1, undeclared: 0 } }
  let(:golf) { { unit: 3, integration: 0, request: 1, system: 0, undeclared: 0 } }
  let(:charlie) { { unit: 0, integration: 0, request: 0, system: 0, undeclared: 3 } }

  describe ".of" do
    # @intent: { entity: "PyramidShare", action: "answer the share", behavior: "a declared mix answers (request + system) / (unit + integration + request + system) as a fraction: 2/6, 4/10, 1/4 and a measured 0 of 10", layer: "unit" }
    it "answers the request+system share over the declared total" do
      expect(described_class.of(foxtrot)).to eq(2.fdiv(6))
      expect(described_class.of(alpha)).to eq(4.fdiv(10))
      expect(described_class.of(golf)).to eq(1.fdiv(4))
      expect(described_class.of(bravo)).to eq(0.0)
    end

    # A mix with nothing declared has no share: 0.0 would read as "all unit", the reading the
    # ordering deliberately refuses (unmeasured last, not first).
    # @intent: { entity: "PyramidShare", action: "answer the share", behavior: "a mix whose every example is undeclared, and a nil mix, answer nil and never 0.0", layer: "unit" }
    it "answers nil when there is nothing declared to take a share of" do
      expect(described_class.of(charlie)).to be_nil
      expect(described_class.of(nil)).to be_nil
    end
  end

  describe ".operands" do
    # @intent: { entity: "PyramidShare", action: "answer the operands", behavior: "a declared mix answers the [top, declared] pair — [2, 6] for the all-four-layers mix — and an all-undeclared or nil mix answers nil", layer: "unit" }
    it "answers the [top, declared] pair, or nil when nothing is declared" do
      expect(described_class.operands(foxtrot)).to eq([2, 6])
      expect(described_class.operands(bravo)).to eq([0, 10])
      expect(described_class.operands(charlie)).to be_nil
      expect(described_class.operands(nil)).to be_nil
    end
  end

  # The extraction, pinned at the seam: the ordering still reads the ONE expression. A drift here
  # is invisible to the sorting pins (both sides would move together only if the delegate stayed
  # in step), so the equality itself is the assertion — every branch of the rule.
  describe "RepositoryNarrowing#pyramid_share" do
    let(:narrowing) do
      Class.new { include RepositoryNarrowing }.new
    end

    # @intent: { entity: "RepositoryNarrowing", action: "delegate pyramid share", behavior: "the concern's pyramid_share answers PyramidShare.of identically for a measured mix, a measured zero, an all-undeclared mix and a nil mix", layer: "unit" }
    it "answers exactly PyramidShare.of on every branch of the rule" do
      [foxtrot, alpha, golf, bravo, charlie, nil].each do |mix|
        expect(narrowing.send(:pyramid_share, mix)).to eq(described_class.of(mix))
      end

      expect(narrowing.send(:pyramid_share, foxtrot)).to eq(2.fdiv(6))
      expect(narrowing.send(:pyramid_share, bravo)).to eq(0.0)
      expect(narrowing.send(:pyramid_share, charlie)).to be_nil
      expect(narrowing.send(:pyramid_share, nil)).to be_nil
    end
  end
end
