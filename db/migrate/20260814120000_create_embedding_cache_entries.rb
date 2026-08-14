# frozen_string_literal: true

# The last of SPGD-72's three cost levers: **cache the vector, not just the row.**
#
# Batching shipped (`Ingest::IdentityResolver#page_embeddings` asks the provider once per page) and
# skipping byte-identical re-embeds shipped (`#identical_text`, answered from `#digest_index`).
# What neither reaches is the vector a DIFFERENT repository — or this one, before a rename — has
# already been billed for. `digest_index` reads `@repository.spec_identities` against the unique
# `(repository_id, text_digest)` key, so the set it can answer for is *"text currently on one of
# THIS repository's identity rows"*, which is strictly narrower than *"text this deployment has
# ever embedded"*. Every text in that gap is a vector bought twice. `"validates the email format"`
# appears in a great many suites and is one string.
#
# == Why an ActiveRecord table and not `Rails.cache`
#
# The originating proposal asked for a "deployment-global cache" and assumed `Rails.cache` was it.
# It is not, here, for three independent reasons:
#
# * `config/environments/test.rb` sets `cache_store = :null_store`, so a `Rails.cache`-backed
#   implementation is a silent no-op under test. The spec proving zero provider requests on a
#   re-ingest would then be asserting a fiction the deployment does not run — unsatisfiable
#   without mutating test config, which is worse than not having the spec.
# * `config/environments/production.rb` leaves `cache_store` commented out, so production gets the
#   default in-process, non-durable store. Lost on every restart and every deploy.
# * **Decisively:** ingest resolution runs in `Ingest::IdentityResolutionJob` under Solid Queue —
#   a different PROCESS from the web process, and several of them. An in-process cache is invisible
#   across that boundary and each worker would hold its own partial copy, so the writer would never
#   be the reader. That also destroys the cross-repository payoff, which is the larger share of the
#   duplication and the whole reason this is worth doing.
#
# There is no cache gem in the Gemfile at all (no `solid_cache`, `redis`, `dalli`, `kredis`).
# `config/database.yml` carries the project's standing decision in its own comment block — Solid
# Queue lives in the PRIMARY database, there is deliberately no second one, "one database" until
# write volume warrants otherwise. A table in the primary database is the choice consistent with
# that decision rather than a new one: it survives restarts, it is shared by the web and worker
# processes, and it is genuinely deployment-global. `solid_cache` would also work and is a
# defensible alternative, but it is a new dependency and a second database to earn.
#
# == The key is the fingerprint and the DIGEST, and the text is never stored
#
# A vector is a pure function of `(what embedded it, what was embedded)`. The first half is
# `EmbeddingGenerator.fingerprint`; the second is the SHA-256 the caller already holds, because
# `Ingest::IdentityResolver` computes digests for `#digest_index` on the same page.
#
# **Storing the text would be a disclosure and it buys nothing.** This table is deployment-global
# and spans every repository, while identity resolution is repository-scoped and stays exactly that
# — nothing about *which rows match* changes here. A lookup by digest of text the caller is already
# holding needs no text column to answer, so one repository's test descriptions are never readable
# from another's cache hit. The digest is one-way; the vector, on its own, names nothing.
#
# == No HNSW index, deliberately
#
# `spec_identities` and `spec_intents` both index `embedding` with `hnsw (embedding
# vector_cosine_ops)` because resolution asks them for a nearest NEIGHBOUR. This table is never
# asked that. It is a key-value store: every read is an equality on `(provider_fingerprint,
# text_digest)`, and a similarity search against it would be meaningless — it pools every
# repository's texts, so its nearest neighbour is not an answer to any question the resolver asks.
# An HNSW index here would cost build and maintenance time on every insert and serve nothing. The
# `embedding` column is still `vector(1536)` rather than, say, a JSON array, so the width is
# enforced by the column exactly as it is on the other two tables and a provider that changed
# dimensions cannot quietly write a short vector.
#
# == Retention
#
# Stated as a decision with a bound on the model — see `EmbeddingCacheEntry::RETENTION_WINDOW`,
# which is also what the read filters on, and its `expired` / `live` scopes, which make the rule
# queryable. Not enforced by a sweeper in this slice; the constant explains why, and what is left.
class CreateEmbeddingCacheEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :embedding_cache_entries do |t|
      # WHAT embedded the vector. `EmbeddingGenerator.fingerprint`'s value, opaque to this table:
      # any change of provider or model must move it, and a fingerprint that moved makes every
      # prior entry UNREADABLE rather than stale — a key that cannot be hit, not a row that lies.
      # Never carries the credential; see the fingerprint's own comment for why that matters.
      t.string :provider_fingerprint, null: false

      # SHA-256 hex of the embedded text, from `SpecIdentity.digest_for` — the same mapping
      # `spec_identities.text_digest` uses, and defined in only that one place. The text ITSELF is
      # deliberately absent; see "the text is never stored" above.
      t.string :text_digest, null: false, limit: 64

      # 1536 to match `EmbeddingGenerator::DIMENSIONS`. NOT NULL because a row only exists once the
      # provider has answered — a text the provider could not embed is not cached at all, so that
      # it is re-asked next time rather than remembered as a failure.
      t.vector :embedding, limit: 1536, null: false

      t.timestamps
    end

    # The cache key, and the conflict target the page's one `upsert_all` writes onto. Unique
    # because two concurrent ingests embedding the same text under the same fingerprint are the
    # ordinary case, not a race to lose: they converge on one row rather than duplicating.
    #
    # Column order is the read: `provider_fingerprint` is the equality and `text_digest` is the
    # `IN` list, so one index serves the lookup and the conflict resolution both. It also makes
    # "everything written under the fingerprint we have now retired" a prefix scan, which is what a
    # sweeper for the retired half would want.
    add_index :embedding_cache_entries, [:provider_fingerprint, :text_digest], unique: true,
              name: "index_embedding_cache_entries_on_key"

    # `EmbeddingCacheEntry::RETENTION_WINDOW` is a bound on `updated_at`, and both the read filter
    # and the `expired` scope are ranges over it. Without this the read added to every page would
    # be an index scan plus a filter, and the scope that names the reclaimable set would be a
    # sequential scan of the largest table this application writes per-text rows into.
    #
    # `updated_at` and not `created_at`, and the difference is load-bearing: the write is an
    # `upsert_all`, which refreshes `updated_at` on conflict and leaves `created_at` at the first
    # insert. So `updated_at` reads as *"when a provider last actually answered for this key"* —
    # which is the age the window is a bound on — and it is also the only one of the two that an
    # expired-then-re-embedded entry can move. Filtering on `created_at` would make such an entry
    # permanently unreadable AND permanently present: a re-embed on every page, forever, with the
    # row still on disk. See the model's `RETENTION_WINDOW`.
    add_index :embedding_cache_entries, :updated_at
  end
end
