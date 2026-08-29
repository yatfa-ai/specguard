# frozen_string_literal: true

require "rails_helper"

# The stub's determinism is what later threshold assertions rest on, so it is tested like
# production code rather than trusted. See spec/support/embedding_generator.rb.
RSpec.describe DeterministicEmbeddingGenerator do
  # @intent: { entity: "DeterministicEmbeddingGenerator", action: "generate an embedding", behavior: "the stub answers an Array of 1024 Floats matching the column width", layer: "unit" }
  it "returns a vector of exactly 1024 floats" do
    vector = described_class.call("Order checkout returns 402 on expired card")

    expect(vector.size).to eq(1024)
    expect(vector).to all(be_a(Float))
  end

  # @intent: { entity: "DeterministicEmbeddingGenerator", action: "generate an embedding", behavior: "identical input text produces the identical vector on repeated calls within and across runs", layer: "unit" }
  it "gives the same vector for the same string, every time" do
    expect(described_class.call("same text")).to eq(described_class.call("same text"))
  end

  # @intent: { entity: "DeterministicEmbeddingGenerator", action: "generate an embedding", behavior: "distinct texts map to distinct vectors so downstream similarity thresholds mean something", layer: "unit" }
  it "gives different vectors for different strings" do
    expect(described_class.call("one behavior")).not_to eq(described_class.call("another behavior"))
  end

  # @intent: { entity: "DeterministicEmbeddingGenerator", action: "generate an embedding", behavior: "a fixed string pins the first four components to checked-in values, failing loudly if the seeding or width ever drifts", layer: "unit" }
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

  # @intent: { entity: "DeterministicEmbeddingGenerator", action: "generate an embedding", behavior: "the L2 magnitude of the vector is 1.0 within 1e-9, matching real embedding geometry", layer: "unit" }
  it "produces unit-length vectors, like real embeddings" do
    magnitude = Math.sqrt(described_class.call("anything").sum { |v| v * v })

    expect(magnitude).to be_within(1e-9).of(1.0)
  end

  # @intent: { entity: "DeterministicEmbeddingGenerator", action: "install as provider", behavior: "EmbeddingGenerator's provider resolves to this class and dispatches to it transparently", layer: "unit" }
  it "is installed for the whole suite through the public swap seam" do
    expect(EmbeddingGenerator.provider).to eq(described_class)
    expect(EmbeddingGenerator.call("x")).to eq(described_class.call("x"))
  end

  # @intent: { entity: "DeterministicEmbeddingGenerator", action: "generate an embedding", behavior: "generating a vector never constructs a Faraday connection", layer: "unit" }
  it "never reaches the network" do
    expect(Faraday).not_to receive(:new)

    EmbeddingGenerator.call("no api key needed")
  end
end
