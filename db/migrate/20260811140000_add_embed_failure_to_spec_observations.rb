# frozen_string_literal: true

# Makes a failed embedding **identifiable**, which is the precondition for making it retryable.
#
# `spec_observations.spec_identity_id` is nullable and `CreateSpecIdentities` says why: the
# unresolved state was deliberately pushed *here* rather than allowed to live as a NULL embedding on
# `spec_identities`, where `neighbor`'s `.where.not(embedding: nil)` would have hidden it from
# resolution forever. That was the right place to put it. What it did not do — and said so, handing
# the rest to this work by name — is say WHICH unresolved state a given NULL is.
#
# == One NULL, three meanings
#
# `SpecObservation.unresolved` is `where(spec_identity_id: nil)`, and today that one predicate pools
# three populations that want three different answers:
#
# 1. **Not attempted yet.** The row is written inside the ingest transaction and
#    {Ingest::IdentityResolutionJob} runs afterwards, so every row is in this state for a while.
#    Nothing is wrong; wait.
# 2. **Nothing to embed.** `Ingest::SpecSignal#present?` is false — no intent and no name — so there
#    is no text and therefore no identity to have. Permanent, and correct. `IdentityResolver`'s
#    comment calls it "the honest answer rather than an identity standing for nothing".
# 3. **The embedding failed.** `IdentityResolver#embed` rescued an `EmbeddingGenerator::Error` and
#    returned nil. Recoverable — the same text embeds fine once the provider is back — and the only
#    one of the three anybody would want to act on.
#
# Nobody could ask "how many examples did this run fail to embed?", because the answer was mixed in
# with (1) and (2). And no retry could be written, because a retry has to know which rows to retry:
# sweeping every NULL would mean re-embedding case (2) forever and racing case (1).
#
# == Why the discriminator is a POSITIVE stamp and not a status enum
#
# `embed_failed_at` is written only where the failure actually happens, so its presence is evidence
# rather than a classification of an absence. That is what lets it separate case (3) from BOTH the
# others with one predicate, without anything re-deriving the intent-or-name precedence in SQL —
# `SpecObservation#signal` states that the precedence has exactly one owner and that a copy of it
# would drift. A `state` column would have had to be written on every path, including the two where
# nothing happened, to say the same thing worse.
#
# It records the **first** failure and is never overwritten (`COALESCE`d in
# {Ingest::IdentityResolver#record_embed_failure}), because it anchors the retry window: a timestamp
# refreshed on every attempt is a window that never closes.
#
# `embed_failure_count` is how many attempts have failed on the row. Deliberately **not** the cap —
# see `SpecObservation::EMBED_RETRY_WINDOW` for why an attempt cap is the wrong bound here — it
# orders the sweep so a backlog larger than one sweep drains fairly instead of starving its tail,
# and it is what tells an operator a flaky provider from a text that will never embed.
#
# == The index is partial, and that is the whole cost story
#
# The sweep runs on **every ingest**, so an unindexed one would be a repository-wide scan of a table
# holding `BRANCH_RETENTION_RUNS` runs of a 20,000-example suite per branch — to find, on a healthy
# repository, nothing at all. The partial predicate is exactly the backlog: rows that failed and are
# still unresolved. On a repository whose provider has never failed the index is EMPTY, so the sweep
# costs an empty index probe per ingest and the index itself costs nothing to carry.
#
# The column order is the sweep's: `repository_id` narrows, then the two ordering keys
# (`embed_failure_count`, `embed_failed_at`) are read in index order so the `LIMIT` can stop early
# rather than sorting the whole backlog. Rows leave the index by being resolved, which is what makes
# it self-draining rather than a second thing to prune.
class AddEmbedFailureToSpecObservations < ActiveRecord::Migration[8.1]
  def change
    add_column :spec_observations, :embed_failed_at, :datetime
    add_column :spec_observations, :embed_failure_count, :integer, null: false, default: 0

    add_index :spec_observations, %i[repository_id embed_failure_count embed_failed_at],
              where: "embed_failed_at IS NOT NULL AND spec_identity_id IS NULL",
              name: "index_spec_observations_on_embed_backlog"
  end
end
