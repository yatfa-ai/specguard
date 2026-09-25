# frozen_string_literal: true

# THE STORED NEAR-DUPLICATE CENSUS — one row per repository, the persisted answer to
# "where in the suite is the same logic tested more than once, and what does it cost".
#
# ## Why this table exists at all
#
# `NearDuplicateClusters` was computed LIVE on every `?near_duplicates=` ask, and its own class
# comment carries the measurements that made that untenable: linear in the suite, seconds at a few
# thousand identities, tens of seconds extrapolated at the 20,000-identity design point. The agent
# bridge enforces a per-call deadline two orders of magnitude below that, so the product's core
# question was unreachable from the consumer it was built for — every agent call failed, retries
# included. The census is a pure derivative of ingested data — its inputs (`spec_identities`,
# `spec_observations`, and the repository's newest run as the weighed run) change only at ingest —
# so the computation belongs to ingest, not to the request path. This table is where the ingest
# half lands: {Ingest::NearDuplicateCensusJob} computes the census once after identity resolution
# and writes the serialized result here, and `RepositoryOverview#serialized_near_duplicates`
# serves what is stored. The MCP tool does not change; its answer arrives in milliseconds instead
# of never.
#
# ## Why the payload is the serialized census, and not the pairs
#
# **Storing clusters, not raw pairs, is a bound on this table's growth.** The pair read returns up
# to `identities × k` edges — two million at the design point — and they are an intermediate: the
# census's answer is the handful of clusters they assemble into. A `payload` json holding the
# serialized clusters stores the ANSWER at the size the wire response already was, and serving is
# a read of that column, not a re-assembly.
#
# The payload is also what makes "between ingests, stored equals live" hold **by construction**
# rather than by argument: the writer serializes the very `NearDuplicateClusters` object the live
# path would have built, from the same frozen inputs, and the serve path returns those bytes
# verbatim. Nothing re-derives anything on the way out.
#
# ## The three stamps, and what each is for
#
# * `weighed_run_id` — WHICH RUN every weight, timing and coverage figure in the payload was
#   measured in. It is a column beside the payload rather than a key inside it for the same reason
#   it was a method on the live object: it is the caption that makes the figures readable, and one
#   writer sets both in one statement so they can never disagree. Deliberately **no foreign key**:
#   this column is a stamp naming the run the artifact was weighed on, not an association whose
#   integrity the census depends on, and the census must outlive the runs it names rather than
#   block a run's deletion on it. A payload whose figures reference a run that no longer exists
#   still reads fine — it is a historical measurement.
# * `computed_at` — WHEN the stored artifact was computed. This is what lets a consumer tell a
#   fresh census from a stale one, and it is the reason a census that has not been computed yet is
#   served as `null` rather than as zeros: a block without this stamp is not a census answer, and
#   "no answer yet" must not render as "the answer was: nothing reads alike". See
#   `RepositoryOverview#serialized_near_duplicates` for the serving rule.
# * `refresh_wanted_at` — the recompute marker, and the debounce that makes one sharded ingest
#   cost one census computation instead of one per shard. See `request_refresh!`.
#
# ## The no-clusters state is a row, not an absence
#
# A repository whose every test reads differently gets a row whose `clusters` array is empty and
# whose population counts are real — the honest empty ranking, stored. `payload` is nil only for a
# row that has been marked for refresh before its first computation ever ran, and that state is
# never served: it is the plumbing of the marker below, not a census.
class CreateNearDuplicateCensuses < ActiveRecord::Migration[8.1]
  def change
    create_table :near_duplicate_censuses do |t|
      # The grain of the census — one stored answer per repository. Unique, because the census is
      # parameterless from the consumer's side: threshold, limit and the weighed run are the
      # server's own constants and defaults, so there is exactly one artifact to hold. The unique
      # index is also the conflict target the marker upsert resolves against.
      t.references :repository, null: false, foreign_key: true, index: { unique: true }

      # WHICH RUN the payload's weight figures were measured in — `NearDuplicateClusters#weighed_run_id`
      # at write time. Nullable: a repository that has ingested nothing has a census of all-zero
      # populations and no run to name. No foreign key, deliberately — see this file's header.
      t.bigint :weighed_run_id

      # WHEN the stored artifact was computed. The freshness stamp the served block states, and
      # the field that distinguishes "computed, and it found nothing" from "never computed".
      t.datetime :computed_at

      # THE STORED CENSUS — the serialized clusters and their summary figures, exactly as the
      # request path used to assemble them live. `json`, not `jsonb`, ON PURPOSE, and not for
      # size or indexing: jsonb NORMALIZES its keys (sorted by length, then bytewise, duplicates
      # dropped), so the written order of `snapshot_payload` — `similarity_floor` and
      # `similarity_basis` first, ahead of every figure they qualify — would be silently
      # re-sorted into a different order on the way out. The served block's disclosure contract
      # states that order (see `RepositoryOverview#serialized_near_duplicates` and the MCP
      # tool's README), so the column must preserve what the writer wrote, which is exactly
      # what `json` is: the text as sent, read back in the order it was written. It is written
      # once per ingest and read whole, never queried by content, so jsonb's containment and
      # indexing machinery buys nothing here.
      t.json :payload

      # THE RECOMPUTE MARKER. Set by the ingest half, cleared by the job that honoured it — the
      # debounce and the freshness contract in one column. See `request_refresh!` on the model.
      t.datetime :refresh_wanted_at

      t.timestamps
    end
  end
end
