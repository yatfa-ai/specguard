# frozen_string_literal: true

require "rails_helper"

# The lexical stand-in the identity-resolution specs run on (spec/support/lexical_embeddings.rb).
# **Not application code** — it is the feature-hashing provider this repository shipped until
# 2026-08-17, kept because `DeterministicEmbeddingGenerator` models identity and not meaning, and
# `Ingest::IdentityResolver`'s thresholds cannot be asserted against near-orthogonal noise.
#
# It is specced for the same reason `DeterministicEmbeddingGenerator` is: the resolution specs read
# as claims about the resolver, and they are only that if the vectors underneath them have the
# properties those claims assume. A silent change here would move `identity_resolver_spec.rb` from
# testing the resolver to testing this file, and it would stay green while doing it.
RSpec.describe LexicalEmbeddingProvider do
  before { EmbeddingGenerator.provider = described_class }

  def cosine(one, two)
    one.each_with_index.sum { |value, index| value * two[index] }
  end

  def magnitude(vector)
    Math.sqrt(vector.sum { |value| value * value })
  end

  describe "the vector it produces" do
    # @intent: { entity: "LexicalEmbeddingProvider", action: "produce the vector", behavior: "the output is exactly DIMENSIONS Floats, clearing the interface's shape validation", layer: "unit" }
    it "is DIMENSIONS floats wide, so it clears the interface's validation" do
      vector = EmbeddingGenerator.call("Order checkout returns 402 payment required on expired card")

      expect(vector.size).to eq(EmbeddingGenerator::DIMENSIONS)
      expect(vector).to all(be_a(Float))
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "normalise to a unit vector", behavior: "the produced vector has magnitude 1 so cosine similarity against any other vector is well-defined", layer: "unit" }
    it "is unit-normalised, so cosine ranks it against any other vector" do
      vector = described_class.call("A sharded CI run accumulates into a single TestRun row")

      expect(magnitude(vector)).to be_within(1e-12).of(1.0)
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "stay normalised under saturation", behavior: "a text with far more features than buckets still yields a finite unit vector of the right width", layer: "unit" }
    it "stays a unit vector when a text has far more features than there are dimensions" do
      # 1024 buckets, thousands of features: every dimension is hit many times and the weights sum.
      # The result must still be normalised, still finite, still the right width.
      vector = described_class.call(("the quick brown fox jumps over the lazy dog " * 200))

      expect(vector.size).to eq(EmbeddingGenerator::DIMENSIONS)
      expect(vector).to all(be_finite)
      expect(magnitude(vector)).to be_within(1e-12).of(1.0)
    end
  end

  describe "determinism" do
    # @intent: { entity: "LexicalEmbeddingProvider", action: "map deterministically", behavior: "the same text yields the same vector, pinned by a SHA-256 checksum of its packed floats", layer: "unit" }
    it "returns a byte-identical vector for the same text, pinned by checksum" do
      # A golden checksum rather than a re-run comparison: it pins the mapping across runs and
      # processes ON THIS PLATFORM, which is what every similarity number in
      # `identity_resolver_spec.rb` is asserted against.
      #
      # What it does NOT pin is cross-platform bit-equality. Everything up to the weight is exact
      # integer work, but `Math.sin` delegates to the host libm and glibc/musl/Darwin may differ in
      # the last ULP. So read a failure in the order: if the C library or CPU architecture changed
      # (a new base image), suspect a benign rounding difference and confirm by checking whether the
      # vectors differ only in their low bits. Otherwise the mapping itself changed — and the
      # resolution specs' thresholds are being asserted against different vectors than the ones they
      # were chosen from. In neither case is this a spec to "just update" to whatever the new value
      # happens to be.
      #
      # ⚠️ This value moved on 2026-08-17 with `EmbeddingGenerator::DIMENSIONS`: the same features
      # hashed into 1024 buckets rather than 1536 land in different dimensions, so the vector is a
      # different vector. It is not evidence of a change in the algorithm.
      vector = described_class.call("Order checkout returns 402 payment required on expired card")

      expect(Digest::SHA256.hexdigest(vector.pack("E*")))
        .to eq("72377a41cdc3be89780318b910f4e42ecb61db9cc9f10aad9701da253e8d7212")
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "separate distinct texts", behavior: "two different texts produce different vectors", layer: "unit" }
    it "gives different text a different vector" do
      expect(described_class.call("charges the card")).not_to eq(described_class.call("refunds the card"))
    end
  end

  describe "what it actually measures" do
    let(:expired_card) { described_class.call("rejects checkout on an expired card") }

    # @intent: { entity: "LexicalEmbeddingProvider", action: "cluster shared vocabulary", behavior: "a restatement sharing the original's words scores cosine above 0.5", layer: "unit" }
    it "clusters two names that share vocabulary" do
      restated = described_class.call("rejects checkout when the card is expired")

      expect(cosine(expired_card, restated)).to be > 0.5
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "tolerate a changed suffix", behavior: "texts differing only in a word ending still score cosine above 0.3 via shared trigrams", layer: "unit" }
    it "tolerates a changed suffix, because n-grams overlap where words do not" do
      # "expired"/"expires" share no word feature at all; they share four of their five trigrams.
      expect(cosine(expired_card, described_class.call("rejects checkout on a card that expires")))
        .to be > 0.3
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "ignore punctuation and spacing", behavior: "punctuation, case and repeated whitespace leave the vector unchanged", layer: "unit" }
    it "ignores punctuation and repeated whitespace" do
      expect(described_class.call("Order#checkout")).to eq(described_class.call("  order   CHECKOUT!  "))
    end

    # The documented limitation, asserted rather than merely written down — and the whole reason
    # this is spec support and not the shipped provider. Two names for the same behaviour that share
    # no vocabulary are near-orthogonal, exactly as if they were unrelated.
    # @intent: { entity: "LexicalEmbeddingProvider", action: "fail on paraphrase", behavior: "the same behaviour described with entirely different vocabulary scores cosine below 0.1, near-orthogonal", layer: "unit" }
    it "does NOT match the same behaviour described in different words" do
      payment_required = described_class.call("returns 402 payment required")
      rejection = described_class.call("declines the purchase")

      expect(cosine(payment_required, rejection)).to be < 0.1
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "separate unrelated names", behavior: "unrelated names score cosine below 0.2", layer: "unit" }
    it "gives unrelated names a low similarity" do
      expect(cosine(expired_card, described_class.call("paginates the audit log"))).to be < 0.2
    end
  end

  describe "text with nothing in it" do
    # No alphanumeric content means no features and so no direction. Zero is the honest answer, and
    # it must still clear the interface's width and finiteness validation rather than blowing up
    # somewhere downstream.
    # @intent: { entity: "LexicalEmbeddingProvider", action: "zero a punctuation-only text", behavior: "text with no alphanumeric content yields a finite zero vector of the correct width", layer: "unit" }
    it "returns a finite zero vector of the right width for punctuation-only text" do
      vector = EmbeddingGenerator.call("--- !!! ---")

      expect(vector.size).to eq(EmbeddingGenerator::DIMENSIONS)
      expect(vector).to all(eq(0.0))
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "zero an empty string", behavior: "an empty string returns the zero vector rather than raising", layer: "unit" }
    it "returns a zero vector for an empty string rather than raising" do
      expect(described_class.call("")).to eq(Array.new(EmbeddingGenerator::DIMENSIONS, 0.0))
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "zero a nil input", behavior: "a nil input is accepted and returns the zero vector, since callers build text by interpolation", layer: "unit" }
    it "accepts a nil the same way, since callers build text by interpolation" do
      expect(described_class.call(nil)).to eq(Array.new(EmbeddingGenerator::DIMENSIONS, 0.0))
    end
  end

  # `.normalize` is what makes `EmbeddingGenerator.equivalent?` answerable at all, and therefore
  # what makes `Ingest::IdentityResolver#note_drift` reachable in a spec. Production's provider
  # publishes none, so this is the only place that path runs.
  describe ".normalize" do
    # @intent: { entity: "LexicalEmbeddingProvider", action: "normalize to canonical form", behavior: "normalize folds punctuation, case and whitespace runs into one lowercase form", layer: "unit" }
    it "reduces punctuation, case and runs of whitespace to one canonical form" do
      expect(described_class.normalize("Order#checkout   rejects  an Expired card!"))
        .to eq("order checkout rejects an expired card")
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "normalize non-alphanumeric text", behavior: "punctuation-only and nil inputs normalize to an empty string, matching the zero-vector behaviour", layer: "unit" }
    it "has nothing to say about text with no alphanumeric content, exactly as the vector does" do
      expect(described_class.normalize("--- !!! ---")).to eq("")
      expect(described_class.normalize(nil)).to eq("")
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "agree with the vector", behavior: "texts with the same normalized form produce byte-identical vectors", layer: "unit" }
    it "agrees with the vector: same normalised form means the same floats" do
      # The property the resolver acts on, asserted as an equality of VECTORS and not of strings.
      one = "Order#checkout rejects an expired card"
      other = "Order  checkout   rejects an expired card!"

      expect(described_class.normalize(one)).to eq(described_class.normalize(other))
      expect(described_class.call(one)).to eq(described_class.call(other))
    end

    # @intent: { entity: "LexicalEmbeddingProvider", action: "keep real edits distinct", behavior: "a one-character edit survives normalization and the two vectors differ accordingly", layer: "unit" }
    it "does not collapse a real edit, so the vectors differ too" do
      one = "Order#checkout rejects an expired card"
      other = "Order#checkout rejects an expired cards"

      expect(described_class.normalize(one)).not_to eq(described_class.normalize(other))
      expect(described_class.call(one)).not_to eq(described_class.call(other))
    end
  end
end
