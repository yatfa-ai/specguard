# frozen_string_literal: true

# A vector this deployment has already been billed for, keyed by WHAT embedded it and WHAT was
# embedded — `(provider_fingerprint, text_digest)`.
#
# The last of SPGD-72's three cost levers, and the only one that is not a batching restatement.
# `Ingest::IdentityResolver#digest_index` already answers *"is this text on one of THIS
# repository's identity rows"* in one query per page, and a hit there skips the embed entirely.
# What it cannot answer is *"has this deployment ever embedded this text"* — a different
# repository's copy of `"validates the email format"`, or this repository's own copy from before a
# rename moved the row's text out from under the index. Those are vectors bought twice, and this
# table is where the second purchase stops. See the migration for why the substrate is a table in
# the primary database and not `Rails.cache`.
#
# == It is a CACHE, and every caller must be able to lose it
#
# Nothing here is a source of truth. The vector is reproducible by asking the provider again, which
# is exactly what a miss does, so a read that fails, a write that fails, an empty table and a table
# that was dropped are all the same thing to a caller: today's behaviour, at today's price. That is
# why `Ingest::IdentityResolver` rescues around these two calls and why neither of them raises past
# a caller that forgot to — see `#cached_embeddings` there for the containment argument.
#
# == The text is never stored
#
# The key's second half is a SHA-256 the caller already holds. There is no `text` column and there
# must not be one: this table is deployment-global while identity resolution is repository-scoped,
# so a text column would make one repository's test descriptions readable from another's cache row,
# in exchange for nothing — a lookup by digest needs no text to answer. The digest is one-way and a
# vector on its own names nothing.
#
# Nothing about WHICH ROWS MATCH changes because of this table. It makes the repeat embed free; it
# does not widen what any repository can see, and it does not touch what an identity says it is.
class EmbeddingCacheEntry < ApplicationRecord
  # How long a cached vector may be served before the provider is asked again.
  #
  # **What this is a bound on is provider drift the fingerprint cannot see.** A fingerprint is a
  # claim about what will embed the text — `"openai:text-embedding-3-small"` — and it moves when
  # the provider or the configured model moves. It does NOT move when a vendor changes what a
  # stable model name returns underneath it, which vendors do. Without a window, an entry written
  # under such a name is served forever and the drift is permanent and invisible; with one, the
  # exposure is bounded at 90 days and self-heals without anyone noticing it happened.
  #
  # It is emphatically NOT a correctness mechanism, and the fingerprint is. A provider or model
  # change makes every prior entry **unreadable rather than stale** — a key nothing can hit, at the
  # instant of the change — because a wrong vector is not something to be eventually consistent
  # about. This window only covers the case where the key stayed honest and the answer did not.
  #
  # 90 days, and the number is chosen by what it costs to be wrong in each direction. Too short
  # re-buys vectors the cache exists to stop re-buying; too long extends the drift exposure above.
  # The cost of expiry is bounded and small — one re-embed per text per window, on the page that
  # meets it, at which point the `upsert_all` refreshes `updated_at` and the entry is live again
  # for another window. A suite that is ingested continuously therefore pays 1/90th of a cold start
  # per day in the worst case, spread across pages, and pays nothing at all for the texts it has
  # renamed away from.
  #
  # ⚠️ **This bounds what is READ, not what is stored.** The window is enforced by `live`, which
  # `.vectors_for` filters on, so an expired entry stops being served the moment it expires. It is
  # not enforced by a sweeper: reclaiming the disk is a scheduled-deletion concern with its own
  # batching and convergence problem (`Ingest::ObservationPruner` is what that costs when done
  # properly), and it is not this slice's. `expired` is the queryable set for whoever does it, and
  # the index on `updated_at` is what makes that scan affordable. Until then the table grows, and
  # the honest figure is ~6KB per distinct text per fingerprint.
  RETENTION_WINDOW = 90.days

  # Readable: written by a provider within the window. The read filters on this, so "expired" and
  # "not cached" are the same answer to a caller, which is the property that lets the window be
  # changed without anything downstream knowing.
  scope :live, -> { where(updated_at: RETENTION_WINDOW.ago..) }

  # The reclaimable set — rows past the window, which nothing will ever serve again. Queryable so
  # that the retention rule is a fact about this table rather than a sentence in a comment, and so
  # that a sweeper, when there is one, has the set already named rather than re-deriving it.
  scope :expired, -> { where(updated_at: ...RETENTION_WINDOW.ago) }

  # Every text of this page that this deployment has already embedded under this fingerprint.
  #
  # @param fingerprint [String] `EmbeddingGenerator.fingerprint` — the caller has already
  #   established it is present, because a nil fingerprint means no caching at all.
  # @param texts [Array<String>] the page's texts, deduped by the caller.
  # @return [Hash{String => Array<Float>}] text => vector, for the subset that hit. A miss is
  #   simply absent, so `texts - result.keys` is the set still to be embedded.
  #
  # **One query for the whole page**, as an `IN` list on the unique key — the same page-shaped seam
  # `#digest_index` already occupies, and for the same reason: the cost is per page and the
  # decision stays per row. A lookup driven from `#embedding_for` would be a round trip per row,
  # which on a 20,000-example changed suite is the shape this whole lineage exists to remove.
  #
  # The digests are computed here rather than accepted as an argument so that the mapping used to
  # WRITE and the mapping used to READ cannot drift apart — both go through `SpecIdentity.digest_for`,
  # which is the one place SHA-256-of-the-text is defined. The digest => text map is kept locally
  # and only the digests cross into SQL, which is what keeps the "text is never stored" promise
  # true of the query as well as of the schema.
  #
  # `where(text_digest: [])` compiles to `1=0` and Rails answers it without a round trip, so an
  # empty page costs nothing and needs no guard — the same property `#digest_index` relies on.
  #
  # == A cached vector is float4, and so is every vector this application keeps
  #
  # `vector(1536)` is float4 per element, so what comes back here is the provider's float64 answer
  # rounded to single precision — `0.9993489583…` returns as `0.99934894`. That is NOT a difference
  # between the cached path and the fresh one in any way a caller can observe, because the fresh
  # vector's only destinations are the same precision: `spec_identities.embedding` is `vector(1536)`
  # too, and the cosine comparison in `#nearest` runs against rows already stored at float4. The
  # relative error is ~1e-7 against thresholds of 0.95 and 0.88. Stated because "the cache returns
  # exactly what the provider returned" is the obvious assumption and it is false — a spec asserting
  # byte-equality of a cached vector against a freshly generated one would fail, correctly, and the
  # thing to fix would be the spec.
  def self.vectors_for(fingerprint, texts)
    by_digest = texts.to_h { |text| [SpecIdentity.digest_for(text), text] }

    live.where(provider_fingerprint: fingerprint, text_digest: by_digest.keys)
        .pluck(:text_digest, :embedding)
        .each_with_object({}) do |(digest, vector), found|
          found[by_digest.fetch(digest)] = vector
        end
  end

  # Remember this page's freshly bought vectors, in ONE statement.
  #
  # @param fingerprint [String] what embedded them.
  # @param vectors_by_text [Hash{String => Array<Float>, nil}] the page's fresh answers, exactly as
  #   `Ingest::IdentityResolver#embed_page` returns them.
  # @return [void]
  #
  # **Nils are dropped rather than stored.** `#embed_page`'s fallback path answers one text at a
  # time and each of those can fail on its own, so the hash can carry a nil for a text the provider
  # refused. A nil is not an answer about the text — it is the absence of one — and caching it
  # would turn a transient provider failure into a permanent one for every repository that ever
  # ships that string. The row is left uncached so the next page asks again, which is precisely
  # what `SpecObservation`'s retry machinery upstream is counting on.
  #
  # `upsert_all` onto the unique key, because two ingests embedding the same text under the same
  # fingerprint at the same moment is the ordinary case on a sharded first run and not a race to
  # lose. On conflict the vector is rewritten with the one just bought — same input, same
  # fingerprint, so it is the same vector — and `updated_at` is moved to now, which is what makes
  # an expired entry live again and is why `live` filters on that column. `created_at` is left at
  # the first insert, so the table still records when a text was first seen after a refresh.
  #
  # ⚠️ **The explicit `on_duplicate` is what makes the refresh happen at all, and it cannot be
  # dropped in favour of `record_timestamps:`.** Rails 8's generated clause is a touch-ONLY-IF-
  # CHANGED:
  #
  #   updated_at = CASE WHEN embedding IS NOT DISTINCT FROM excluded.embedding
  #                THEN embedding_cache_entries.updated_at ELSE CURRENT_TIMESTAMP END
  #
  # which is a sensible default everywhere except here, where the re-written vector is *always*
  # identical by construction — that is the entire premise of a cache keyed on what produced it. So
  # the `CASE` would take its left branch every single time, `updated_at` would never move, and an
  # entry that expired once would be unreadable and unrefreshable **forever**: `live` would keep
  # missing it, every page would re-embed the text, `store` would keep not-touching the same row,
  # and the cache would silently stop working for exactly the texts that are used most. It fails as
  # a slow leak with no error, so it is pinned by a spec ("an expired entry is revived...") as well
  # as stated here. `record_timestamps` is still on: it is what puts both columns in the INSERT.
  def self.store(fingerprint, vectors_by_text)
    rows = vectors_by_text.filter_map do |text, vector|
      next if vector.nil?

      { provider_fingerprint: fingerprint, text_digest: SpecIdentity.digest_for(text),
        embedding: vector }
    end
    return if rows.empty?

    upsert_all(rows, unique_by: %i[provider_fingerprint text_digest], record_timestamps: true,
                     on_duplicate: Arel.sql("embedding = excluded.embedding, updated_at = CURRENT_TIMESTAMP"))
  end
end
