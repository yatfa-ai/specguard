# frozen_string_literal: true

# The index for the OTHER side of `embed_failed_at` — the rows the resolver never reached.
#
# `AddEmbedFailureToSpecObservations` named three meanings of one NULL `spec_identity_id` and gave
# the third of them — *the embedding failed* — a positive stamp, an index, and a retry. It left the
# first — *not attempted yet* — uncovered, and said why: *"no retry could be written, because a
# retry has to know which rows to retry: sweeping every NULL would mean re-embedding case (2)
# forever and racing case (1)."*
#
# Both halves of that reason have since been dissolved by shipped code, which is what makes this
# migration derivable now rather than a reopening of a settled decision:
#
# * **Re-embedding case (2) forever** costs nothing. `Ingest::IdentityResolver#identity_for` checks
#   `Ingest::SpecSignal#present?` BEFORE the embed and returns nil there, so a row with no text to
#   embed costs a row read and zero embeddings however many sweeps pass over it. It is also a
#   FROZEN population: `Ingest::Payload#validate_name` now rejects "absent name and no intent", so
#   no new one can be written through the API.
# * **Racing case (1)** is what `SpecObservation::EMBED_ATTEMPT_GRACE` is for — a floor under a
#   row's age, so a row a live job is still on its way to is not swept out from under it. That is a
#   COST guard and not a correctness one: two sweeps over one row converge on the
#   `(repository_id, text_digest)` upsert exactly as two jobs over one run already do.
#
# == What went wrong without it
#
# "Nothing is wrong; wait" holds only if the job is guaranteed to arrive, and nothing guarantees
# that. `Ingest::IdentityResolver`'s loop rescues `EmbeddingGenerator::Error` at the embed call and
# nothing else, so an `ActiveRecord::StatementInvalid`, a dropped connection or a SIGTERM mid-job
# propagates out of `perform`; `ApplicationJob` declares no `retry_on`; and the only `perform_later`
# in the application is per-run, from the ingest request. A row the job never reached therefore does
# not degrade into the recoverable case — it stays in the transient one forever, where by design
# nobody is looking, and neither `.embed_retryable` nor `.embed_abandoned` can even count it.
#
# == Why this needs an index of its own, and why the failure index cannot serve it
#
# `index_spec_observations_on_embed_backlog` is partial on
# `embed_failed_at IS NOT NULL AND spec_identity_id IS NULL`. This sweep's predicate is the
# **complement** of its leading clause, so that index cannot answer it at all.
#
# What answers it without this index is `index_spec_observations_on_spec_identity_id` — a plain
# index on a nullable FK, and a btree indexes its NULLs — followed by a filter and a sort. That is
# not a sequential scan and it is not the cost that matters either: that index does not lead on
# `repository_id`, so the narrow is EVERY unresolved row of EVERY tenant, and it carries no ordering
# key, so the whole result has to be read and sorted to hand back `RETRY_SWEEP_LIMIT` of it. The
# work follows the size of the backlog rather than the size of the cap, on a query that runs on
# every ingest — the hottest path in the application, against a table holding
# `SpecObservation::BRANCH_RETENTION_RUNS` runs of a 20,000-example suite per branch.
#
# This index turns that into a backward walk of one tenant's slice that stops at the cap. Certified
# against a real planner, at a backlog larger than the cap, in
# spec/services/ingest/identity_resolver_spec.rb — including the absence of a `Sort` node, which is
# the half of the claim the index name alone does not carry.
#
# == It is NOT empty on a healthy repository, and that sentence is not transferable
#
# The failure index's comment ends *"on a repository whose provider has never failed the index is
# EMPTY, so … the index itself costs nothing to carry"*. **That claim does not hold here and must
# not be copied.** This index holds every in-flight row between the ingest commit and the resolution
# job's pass — at the design point, briefly, a whole run — plus the frozen signalless tail.
#
# What it is instead is SELF-DRAINING and therefore small in steady state: a row leaves the index by
# being resolved, which is seconds later on a healthy repository, and the writes that maintain it
# are ones the ingest is already making. What it costs to carry is a partial index over the rows
# that are momentarily in flight, not over the table.
#
# == The column order is the sweep's
#
# `repository_id` narrows — identity is per repository, and so is the stranding. `created_at` is
# then both the range predicate (`EMBED_ATTEMPT_GRACE` above, `EMBED_RETRY_WINDOW` below) and the
# leading ordering key, read in index order so the `LIMIT` can stop early rather than sorting the
# whole backlog. `id` is in the index because it is the TIEBREAK and the ties are the normal case,
# not an edge one: `Ingest::ObservationRecorder` writes a run's observations in a single bulk
# statement, so twenty thousand rows can share a `created_at` to the microsecond and an ordering
# without `id` would cap an arbitrary slice of them differently on every ingest.
class AddUnattemptedEmbedIndexToSpecObservations < ActiveRecord::Migration[8.1]
  def change
    add_index :spec_observations, %i[repository_id created_at id],
              where: "embed_failed_at IS NULL AND spec_identity_id IS NULL",
              name: "index_spec_observations_on_unattempted_embed_backlog"
  end
end
