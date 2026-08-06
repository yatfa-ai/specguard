# frozen_string_literal: true

require "digest"

# Deterministic stand-in for the embedding provider, installed for the whole suite (see the
# RSpec.configure block at the bottom). No spec ever reaches the network, and no spec needs an
# API key — `bin/rspec` is green with OPENAI_API_KEY unset.
#
# ## The determinism is a load-bearing property, not a convenience
#
#   * **Same text in, same vector out** — byte-identical, across examples, processes and runs. The
#     vector is derived from SHA-256 of the input, so it depends on nothing but the string.
#   * **Different text in, different vector out** — distinct inputs give distinct seeds.
#
# Phase 3's IntentChecker specs assert concrete similarity scores against the duplicate-detection
# thresholds (0.88 duplicate / 0.75 partial). Those assertions are only
# meaningful because this mapping is stable — if it ever became run-dependent, threshold specs
# would flake rather than fail, which is worse. Treat "same string → same vector" as part of the
# contract of this file and do not "improve" it with anything non-reproducible.
#
# Vectors are unit-normalised, like real OpenAI embeddings, so cosine similarity behaves sensibly.
# Values are pseudo-random, so two different strings are near-orthogonal regardless of how similar
# they read — this stub models *identity*, not *meaning*. A spec that needs a specific similarity
# should assign vectors explicitly rather than expect semantics from this.
class DeterministicEmbeddingGenerator
  DIMENSIONS = EmbeddingGenerator::DIMENSIONS

  def self.call(text)
    # Mersenne Twister with an explicit seed: specified, portable, and stable across Ruby versions.
    seed = Digest::SHA256.hexdigest(text.to_s).to_i(16) % (2**64)
    rng = Random.new(seed)
    unit_normalise(Array.new(DIMENSIONS) { rng.rand(-1.0..1.0) })
  end

  def self.unit_normalise(vector)
    magnitude = Math.sqrt(vector.sum { |value| value * value })
    return vector if magnitude.zero?

    vector.map { |value| value / magnitude }
  end
  private_class_method :unit_normalise
end

RSpec.configure do |config|
  # Installed via the public swap seam — the same one production code would use to drop in a
  # different vendor — rather than by stubbing constants.
  config.before { EmbeddingGenerator.provider = DeterministicEmbeddingGenerator }
  config.after { EmbeddingGenerator.provider = nil }
end
