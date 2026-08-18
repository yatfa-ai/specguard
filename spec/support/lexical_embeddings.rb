# frozen_string_literal: true

require "digest"

# A lexical embedder, for the identity-resolution specs only. **Not shipped**: the application has
# one provider, `EmbeddingGenerator::VoyageProvider`, and this file is not it.
#
# ## Why the specs cannot use either of the real options
#
# `spec/support/embedding_generator.rb` installs `DeterministicEmbeddingGenerator` for every
# example, and its own header says what it is: *"Values are pseudo-random, so two different strings
# are near-orthogonal regardless of how similar they read — this stub models identity, not
# meaning."* Under it, `"rejects an expired card"` and `"rejects an expired card "` are two
# unrelated vectors. A resolution spec written against that stub would pass or fail for reasons that
# have nothing to do with the logic under test: the ten-line-shift case would still resolve (same
# string, same seed, cosine 1.0), but every "close but not the same" and "similar but different"
# assertion would be measuring the stub's randomness instead of the threshold.
#
# `VoyageProvider` is the other direction of wrong: an HTTPS round trip and a billed request per
# example, and unavailable to anyone running `bin/rspec` without a key.
#
# So these groups run the provider below — deterministic, in-process, no credentials and no network,
# and *lexical*, so that two texts sharing vocabulary really do land near each other and
# `SpecIdentity::MATCH_SIMILARITY` is asserted against vectors with the property it was chosen for.
#
#   RSpec.describe Ingest::IdentityResolver do
#     include_context "with lexical embeddings"
#     …
#   end
#
# ## What it is
#
# Feature hashing — the implementation this application shipped as
# `EmbeddingGenerator::LocalProvider` until 2026-08-17, moved here when the application stopped
# having a second provider. It measures LEXICAL overlap and not meaning, which is what disqualified
# it from production and what makes it a usable stand-in here, where the assertions are about
# identity and thresholds rather than about semantics.
#
#   1. Downcase and split into alphanumeric word tokens, then rejoin with single spaces.
#   2. Take the words themselves and every 3-character n-gram of the rejoined string.
#   3. SHA-256 each feature: the first 8 bytes pick its dimension, a *different* 4 bytes pick a
#      signed weight, so index and weight are independent rather than two views of one number.
#   4. Accumulate — colliding features sum, and the signs make a collision perturb an inner product
#      instead of inflating it.
#   5. L2-normalise, so cosine ranks sensibly.
#
# `.normalize` is public and load-bearing: `EmbeddingGenerator.equivalent?` asks the provider which
# of its inputs collapse together, and `Ingest::IdentityResolver#note_drift` — inert in production,
# under a provider that publishes no normalisation — is exercised here through it.
class LexicalEmbeddingProvider
  NGRAM_SIZE = 3

  # The hash-to-phase resolution: 2**32 distinct weights per feature, taken from bytes 8..11 of the
  # digest. `Math.sin` of a raw SHA-256 digest is not portable — argument reduction that far out is
  # libm-specific, and a 256-bit integer does not survive `to_f` at all — so the argument is kept
  # inside one period.
  PHASE_STEPS = 2**32
  PHASE_STEP_RADIANS = (2 * Math::PI) / PHASE_STEPS

  WORD = /[[:alnum:]]+/

  class << self
    def call(text)
      new(text).call
    end

    # The ONLY thing the vector is a function of: `#features` reads its words and its n-grams off
    # this string and nothing else touches `@text`. So two texts with the same normalised form embed
    # identically — not approximately, not at cosine 1.0 within tolerance, but to the same array of
    # floats.
    def normalize(text)
      text.to_s.downcase.scan(WORD).join(" ")
    end

    def configured?
      true
    end
  end

  def initialize(text)
    @text = text.to_s
  end

  def call
    vector = Array.new(EmbeddingGenerator::DIMENSIONS, 0.0)

    features.each do |feature|
      index, phase = Digest::SHA256.digest(feature).unpack("Q>N")
      vector[index % EmbeddingGenerator::DIMENSIONS] += Math.sin(phase * PHASE_STEP_RADIANS)
    end

    unit_normalise(vector)
  end

  # Its words, then its 3-character n-grams, namespaced apart so the word "the" and the trigram
  # "the" are not the same feature counted twice.
  def features
    words.map { |word| "w:#{word}" } + ngrams.map { |ngram| "g:#{ngram}" }
  end

  private

  def words
    normalized.split(" ")
  end

  def ngrams
    return [] if normalized.length < NGRAM_SIZE

    (0..normalized.length - NGRAM_SIZE).map { |offset| normalized[offset, NGRAM_SIZE] }
  end

  def normalized
    @normalized ||= self.class.normalize(@text)
  end

  # A text with no alphanumeric content has no features and so no direction to point in. Zero is the
  # honest answer: it is finite, it is the right width, and pgvector's cosine operator returns NaN
  # distance against it rather than a confident wrong neighbour.
  def unit_normalise(vector)
    magnitude = Math.sqrt(vector.sum { |value| value * value })
    return vector if magnitude.zero?

    vector.map { |value| value / magnitude }
  end
end

RSpec.shared_context "with lexical embeddings" do
  before { EmbeddingGenerator.provider = LexicalEmbeddingProvider }
  # No `after`: spec/support/embedding_generator.rb already resets the provider to nil after every
  # example, and a second reset here would be a copy of that rule rather than a reliance on it.
end
