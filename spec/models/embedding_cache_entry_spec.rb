# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingCacheEntry do
  let(:vector) { Array.new(EmbeddingGenerator::DIMENSIONS) { |i| (i % 7) / 7.0 } }
  let(:fingerprint) { "test-provider:v1" }

  describe ".store and .vectors_for" do
    # @intent: { entity: "EmbeddingCacheEntry", action: "cache a vector", behavior: "a stored text round-trips to its vector within half-precision drift while unstored texts return nothing", layer: "unit" }
    it "returns the vector a text was stored under and nothing for a text that was not" do
      described_class.store(fingerprint, { "a stored text" => vector })

      found = described_class.vectors_for(fingerprint, ["a stored text", "never embedded"])

      expect(found.keys).to eq(["a stored text"])
      # Within the two-byte float the `halfvec` column stores, not exactly: `halfvec(1024)` is IEEE
      # half precision per element and Ruby's Floats are float8, so a round trip rounds — to about
      # three significant decimal digits, four orders of magnitude coarser than the `vector(1536)`
      # this column held until 2026-08-17. That is not a difference between the cached path and the
      # fresh one — `spec_identities.embedding` is the same column type, so the fresh vector is
      # rounded identically the moment it is stored — but it does mean an `eq` here would fail on
      # the substrate rather than on the cache.
      drift = vector.zip(found.fetch("a stored text")).map { |mine, stored| (mine - stored).abs }.max
      expect(drift).to be < 1e-3
    end

    # @intent: { entity: "EmbeddingCacheEntry", action: "cache a vector", behavior: "vectors written under one fingerprint are invisible to a lookup under another fingerprint", layer: "unit" }
    it "partitions entries by fingerprint, so a moved fingerprint cannot read the old ones" do
      # The correctness guarantee the whole key rests on: a vector produced by one model must be
      # UNREADABLE to a deployment running another, not merely old. A wrong vector is valid,
      # rankable and silent.
      described_class.store(fingerprint, { "shared text" => vector })

      expect(described_class.vectors_for("test-provider:v2", ["shared text"])).to be_empty
      expect(described_class.vectors_for(fingerprint, ["shared text"]).keys).to eq(["shared text"])
    end

    # @intent: { entity: "EmbeddingCacheEntry", action: "cache a vector", behavior: "a nil vector is skipped so a refused embed is retried later instead of being remembered as failed", layer: "unit" }
    it "does not store a nil, so a refused text is asked again rather than remembered as failed" do
      # `Ingest::IdentityResolver#embed_page`'s fallback answers one text at a time and each can
      # fail on its own, so the hash it returns can carry nils. A nil is the absence of an answer.
      # Caching it would turn one transient provider failure into a permanent one for every
      # repository that ever ships that string.
      described_class.store(fingerprint, { "good" => vector, "refused" => nil })

      expect(described_class.count).to eq(1)
      expect(described_class.vectors_for(fingerprint, %w[good refused]).keys).to eq(["good"])
    end

    # @intent: { entity: "EmbeddingCacheEntry", action: "cache a vector", behavior: "storing and reading a whole page each compile to a single SQL statement", layer: "unit" }
    it "writes a whole page in ONE statement and reads it back in one" do
      texts = Array.new(5) { |i| "page text #{i}" }.to_h { |text| [text, vector] }

      expect(count_queries { described_class.store(fingerprint, texts) }).to eq(1)
      expect(count_queries { described_class.vectors_for(fingerprint, texts.keys) }).to eq(1)
    end

    # @intent: { entity: "EmbeddingCacheEntry", action: "cache a vector", behavior: "an empty text list costs zero database round trips on both the write and the read", layer: "unit" }
    it "costs no round trip at all for an empty page" do
      # `where(text_digest: [])` compiles to `1=0`, which Rails answers without asking the
      # database — the same property `Ingest::IdentityResolver#digest_index` relies on. Asserted as
      # the absence of the query rather than the presence of a guard.
      expect(count_queries { described_class.vectors_for(fingerprint, []) }).to eq(0)
      expect(count_queries { described_class.store(fingerprint, {}) }).to eq(0)
    end

    # @intent: { entity: "EmbeddingCacheEntry", action: "cache a vector", behavior: "a second store of the same text converges on the existing row instead of raising a uniqueness error", layer: "unit" }
    it "converges two concurrent writes of the same text onto one row instead of raising" do
      # Two shards of a first run embedding the same text under the same fingerprint is the
      # ordinary case, not a race to lose. Without the `ON CONFLICT` clause this raises
      # `ActiveRecord::RecordNotUnique` rather than merely counting wrong.
      described_class.store(fingerprint, { "contended" => vector })

      expect { described_class.store(fingerprint, { "contended" => vector }) }.not_to raise_error
      expect(described_class.count).to eq(1)
    end

    # @intent: { entity: "EmbeddingCacheEntry", action: "cache a vector", behavior: "only a digest of the text is stored, and the plaintext appears in no column or attribute", layer: "unit" }
    it "never stores the text itself" do
      # The privacy shape, asserted against the schema rather than trusted from a comment. This
      # table is deployment-global while identity resolution is repository-scoped, so a `text`
      # column would make one repository's test descriptions readable from another's cache row —
      # in exchange for nothing, because a lookup by digest needs no text to answer it.
      described_class.store(fingerprint, { "Order#checkout rejects an expired card" => vector })

      expect(described_class.column_names).not_to include("text")
      expect(described_class.sole.text_digest)
        .to eq(SpecIdentity.digest_for("Order#checkout rejects an expired card"))
      expect(described_class.sole.attributes.values.grep(String).join)
        .not_to include("Order#checkout")
    end
  end

  describe "the retention rule" do
    # Criterion 5: the rule is stated as a decision with its bound, and it is QUERYABLE — a fact
    # about the table rather than a sentence in a comment.

    # @intent: { entity: "EmbeddingCacheEntry", action: "define retention", behavior: "the retention bound is stated as a ninety-day named constant", layer: "unit" }
    it "states its bound as a constant" do
      expect(described_class::RETENTION_WINDOW).to eq(90.days)
    end

    # @intent: { entity: "EmbeddingCacheEntry", action: "define retention", behavior: "live and expired scopes partition the table by the retention window's cutoff", layer: "unit" }
    it "names the live and the reclaimable sets as scopes" do
      described_class.store(fingerprint, { "fresh" => vector, "ancient" => vector })
      described_class.where(text_digest: SpecIdentity.digest_for("ancient"))
                     .update_all(updated_at: (described_class::RETENTION_WINDOW + 1.day).ago)

      expect(described_class.live.pluck(:text_digest)).to eq([SpecIdentity.digest_for("fresh")])
      expect(described_class.expired.pluck(:text_digest)).to eq([SpecIdentity.digest_for("ancient")])
    end

    # @intent: { entity: "EmbeddingCacheEntry", action: "enforce retention", behavior: "an entry past the window is refused by the read itself even though its row is still on disk", layer: "unit" }
    it "stops serving an entry once it is past the window" do
      # The window is enforced BY THE READ, so "expired" and "not cached" are the same answer to a
      # caller. That is what lets the bound be changed without anything downstream knowing.
      described_class.store(fingerprint, { "ancient" => vector })
      described_class.update_all(updated_at: (described_class::RETENTION_WINDOW + 1.day).ago)

      expect(described_class.vectors_for(fingerprint, ["ancient"])).to be_empty
    end

    # @intent: { entity: "EmbeddingCacheEntry", action: "refresh a cache hit", behavior: "re-storing an expired text revives the row so it is readable again, keeping its original created_at", layer: "unit" }
    it "REVIVES an expired entry when the text is embedded again, rather than stranding it" do
      # ⚠️ **The trap this slice's substrate sets, pinned because it fails as a silent leak.**
      #
      # Rails 8's `upsert_all(record_timestamps: true)` generates a touch-ONLY-IF-CHANGED clause:
      #
      #   updated_at = CASE WHEN embedding IS NOT DISTINCT FROM excluded.embedding
      #                THEN embedding_cache_entries.updated_at ELSE CURRENT_TIMESTAMP END
      #
      # Here the re-written vector is ALWAYS identical — that is the entire premise of a cache
      # keyed on what produced it — so that `CASE` takes its left branch every time and
      # `updated_at` never moves. An entry that expired once would then be unreadable AND
      # unrefreshable forever: `live` keeps missing it, every page re-embeds the text, `store`
      # keeps not-touching the same row, and the cache silently stops working for exactly the
      # texts used most, with the rows still on disk. No error, no failing assertion anywhere
      # else — which is why the explicit `on_duplicate` clause has an example of its own.
      described_class.store(fingerprint, { "hot text" => vector })
      row = described_class.sole
      first_seen = row.created_at
      described_class.update_all(updated_at: (described_class::RETENTION_WINDOW + 1.day).ago)

      described_class.store(fingerprint, { "hot text" => vector })

      expect(described_class.vectors_for(fingerprint, ["hot text"]).keys).to eq(["hot text"])
      expect(described_class.count).to eq(1)
      # `created_at` is left at the first insert, so the table still records when a text was first
      # seen even after it has been refreshed.
      expect(row.reload.created_at).to eq(first_seen)
    end
  end
end
