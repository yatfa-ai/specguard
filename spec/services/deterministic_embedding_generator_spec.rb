# frozen_string_literal: true

require "rails_helper"

# The stub's determinism is what later threshold assertions rest on, so it is tested like
# production code rather than trusted. See spec/support/embedding_generator.rb.
RSpec.describe DeterministicEmbeddingGenerator do
  it "returns a vector of exactly 1024 floats" do
    vector = described_class.call("Order checkout returns 402 on expired card")

    expect(vector.size).to eq(1024)
    expect(vector).to all(be_a(Float))
  end

  it "gives the same vector for the same string, every time" do
    expect(described_class.call("same text")).to eq(described_class.call("same text"))
  end

  it "gives different vectors for different strings" do
    expect(described_class.call("one behavior")).not_to eq(described_class.call("another behavior"))
  end

  it "maps a known string to a known vector — the golden value that catches a silent drift" do
    # Checked in deliberately. Determinism *within* one run is easy to hold by accident; what
    # Phase 3's threshold assertions actually need is that this mapping never moves between runs,
    # machines or Ruby versions. If the seeding or the PRNG changes, this fails loudly here
    # instead of flaking somewhere in IntentChecker later.
    #
    # ⚠️ EXACT on purpose — a `be_within` here would destroy the example. No database and no
    # `halfvec` is involved: this is pure Ruby, so there is no round trip to round anything and
    # nothing to be tolerant of.
    #
    # These four moved on 2026-08-17, when `EmbeddingGenerator::DIMENSIONS` went 1536 -> 1024 with
    # the migration to `halfvec(1024)`. `DeterministicEmbeddingGenerator` draws `DIMENSIONS` values
    # from the seeded MT and then unit-normalises, so BOTH the draw count and the normalisation
    # divisor changed — the vector is correctly different, and re-derived by running the generator
    # at the new width rather than by relaxing the assertion.
    expect(described_class.call("checkout expired card").first(4)).to eq([
      0.03867492795215831,
      -0.03517959915170303,
      -0.04433023291057224,
      -0.006204476092951451
    ])
  end

  it "produces unit-length vectors, like real embeddings" do
    magnitude = Math.sqrt(described_class.call("anything").sum { |v| v * v })

    expect(magnitude).to be_within(1e-9).of(1.0)
  end

  it "is installed for the whole suite through the public swap seam" do
    expect(EmbeddingGenerator.provider).to eq(described_class)
    expect(EmbeddingGenerator.call("x")).to eq(described_class.call("x"))
  end

  it "never reaches the network" do
    expect(Faraday).not_to receive(:new)

    EmbeddingGenerator.call("no api key needed")
  end
end
