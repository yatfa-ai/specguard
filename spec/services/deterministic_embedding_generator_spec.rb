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
    expect(described_class.call("checkout expired card").first(4)).to eq([
      0.031931211139353266,
      -0.029045360076699347,
      -0.03660040501368779,
      -0.005122606469446473
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
