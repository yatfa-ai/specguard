# frozen_string_literal: true

module Ingest
  # Enforces {EmbeddingCacheEntry::RETENTION_WINDOW} against the DISK, which until this class
  # nothing did. The window bounded what was SERVED — `live` is what `.vectors_for` filters on, so
  # an expired entry stopped being readable the moment it expired — and nothing ever deleted a row,
  # so the table grew forever at ~8.5KB of disk per distinct text per fingerprint. `expired` was
  # written as the queryable half of that rule and had zero callers. This is its caller.
  #
  # A retention rule that bounds only the read converts a bounded compute cost into an unbounded
  # storage cost and reports it as a saving. What it is worth reclaiming is stated at the design
  # point rather than in the abstract: 20,000 examples is one cold start, so one repository's first
  # ingest under a new fingerprint writes up to 20,000 rows — ~161MB, nearly all of it TOAST rather
  # than heap; see {DELETE_BATCH_SIZE} for the measurement — and every one of them is
  # unreadable 90 days later and still resident.
  #
  # == ⭐ The key is DEPLOYMENT-GLOBAL, and that is why this converges completely
  #
  # `embedding_cache_entries` is keyed `(provider_fingerprint, text_digest)`. There is no
  # `repository_id` and no `branch` on it — {EmbeddingCacheEntry} argues at length why there is no
  # tenant column and must not be one — so the candidate set is not qualified by anything the
  # caller happens to be holding. An invocation from ANY repository's resolve reaches EVERY expired
  # row this deployment owns, whichever ingest wrote it.
  #
  # ⚠️ **The sibling rule's BUCKET STRUCTURE must not be carried over.** {Ingest::ObservationPruner}
  # is handed a run and reaches only the rows of that run's branch, so it needs a second pass —
  # {Ingest::QuietBucketPruner} — whose whole job is picking a bucket no run in hand belongs to and
  # proving that the pick advances. This class needs no such pass and must not grow one: it has no
  # bucket at all, so an invocation from ANY repository's resolve already sees every expired row
  # this deployment owns. A reader who inherits the sibling's two-half shape will go looking for
  # the partition this one is missing, and there is none to find. What that pair achieves for a
  # repository across successive ingests, one invocation here achieves for the whole table.
  #
  # What still bounds it is TRAFFIC, not reach: a deployment that stops ingesting entirely stops
  # pruning, because the trigger is the next resolve. That is the same trade the trigger paragraph
  # below takes deliberately, and it is a different claim from the sibling's — "nothing runs" rather
  # than "something runs and cannot see these rows".
  #
  # == Bounded per invocation, converging across them
  #
  # The first resolve after this ships can meet the whole accumulated backlog, so the delete is
  # issued in bounded batches with a hard per-invocation ceiling of
  # `DELETE_BATCH_SIZE * MAX_BATCHES_PER_RESOLVE` rows. What that buys is CONVERGENCE rather than
  # completeness: an invocation meeting more than its ceiling reclaims what the ceiling allows and
  # leaves the rest to the next one.
  #
  # The loop cannot stall, and the reason is NOT that a batch takes the oldest rows it can reach:
  # {#delete_batch} issues no `ORDER BY`, and WHICH of the expired rows a batch reaches is the
  # planner's business. It is that every row in the candidate set is already past the window, so any
  # batch is progress — the work left for the next invocation is strictly smaller by exactly what
  # this one deleted, whichever rows those were.
  #
  # Concurrent resolves racing one unpartitioned candidate set was considered and left alone: with
  # no `ORDER BY` and no `SKIP LOCKED`, two passes can select overlapping ids, but the loser's EPQ
  # recheck simply yields a short batch and the early `break` — and a deadlock is caught by
  # `IdentityResolver#reclaim_expired_cache`'s rescue and retried on the next pass. Nothing is
  # lost either way, because these rows are all equally dead. Recorded so it is not re-derived.
  #
  # == Why the resolve pass and not the ingest write path
  #
  # {Ingest::IdentityResolver} is the ONLY writer of this table — `#cached_embeddings` reads it,
  # `#store_embeddings` writes it, and no other production code touches it — so enforcement sits on
  # the path that causes the growth. That is the same rule that puts {Ingest::ObservationPruner} at
  # {Ingest::RunRecorder}, applied to a different table rather than copied to the same call site:
  # `RunRecorder` writes `spec_observations` and writes nothing here, and an ingest under a provider
  # that publishes no fingerprint — the suite's stub, and anything else installed through the swap
  # seam — grows this table not at all while still going through it in full. The shipped
  # `EmbeddingGenerator::VoyageProvider` does publish one, so on a real deployment this table grows
  # and this pruner is the thing that bounds it.
  #
  # The resolve is also already OFF the ingest transaction, by construction rather than by
  # arrangement: it runs in {Ingest::IdentityResolutionJob}. At the `RunRecorder` seam this work
  # would have to be placed after the commit by hand, next to a `run.lock!` whose length is measured
  # and load-bearing, and it would be spent inside the request that owes the client a 202. Here
  # there is no lock to lengthen and no response waiting on it.
  #
  # ⚠️ **The prune is NOT gated on a fingerprint, and that is deliberate.** An expired row is
  # expired whoever wrote it, so a deployment that has switched embedding off entirely — or whose
  # provider has stopped publishing a fingerprint, which turns caching off wholesale — still walks
  # its existing table down to nothing on subsequent ingests. Gating this on `cache_fingerprint`
  # would strand the rows of exactly the deployment that has stopped being able to use them.
  #
  # No `config/recurring.yml` entry, and the trigger is the next ingest for the reason
  # {Ingest::IdentityResolver} already states about its own cross-run sweep: adding a cron is a
  # deployment concern and a second thing that can be off.
  #
  # == ⚠️ The failure policy is the sibling's INVERTED, and reproducing it would be a regression
  #
  # {Ingest::ObservationPruner} deliberately lets a prune failure fail the ingest, reasoning that
  # the failure mode IS the table having outgrown the one rule bounding it and that this is the last
  # thing that should fail invisibly. **That argument does not transfer.** `spec_observations` is
  # the product's data; this table is a CACHE, and {EmbeddingCacheEntry}'s header makes losing it a
  # requirement rather than a tolerance — *"a read that fails, a write that fails, an empty table and
  # a table that was dropped are all the same thing to a caller"*. Both existing call sites honour
  # that already: `#cached_embeddings` and `#store_embeddings` each rescue `StandardError`, log at
  # `warn`, and carry on.
  #
  # A prune that could fail a resolve would make a losable cache load-bearing for the write path —
  # an unrun migration or a saturated pool would stop rows being resolved, which is the one thing
  # this table is forbidden from costing anyone. So the containment lives at the call site, on
  # exactly the terms its sibling write already has: see `IdentityResolver#reclaim_expired_cache`.
  # This class raises rather than rescuing internally, for the same reason `EmbeddingCacheEntry.store`
  # does — the policy belongs to the caller that knows what it is in the middle of, and a rescue
  # here would also swallow the failure for any future caller that wanted to hear about it.
  #
  # == A second reclaimable population, deferred with its reason
  #
  # Rows under a RETIRED fingerprint are dead the instant the fingerprint moves: a provider or model
  # change makes every prior entry unreadable rather than stale, so a cold start's worth of vectors
  # becomes unreachable immediately and only becomes `expired` 90 days later. The composite key's
  # column order makes that population a prefix scan, which the migration notes is what a sweeper
  # for it would want.
  #
  # **This slice does not reclaim it**, and the reason is that the application holds no source of
  # truth for which fingerprints are retired. `EmbeddingGenerator.fingerprint` answers only what the
  # CURRENT one is, and *"not the current one"* is not *"retired"*: a deployment mid-rollout, a
  # worker on an older release, and a provider that transiently failed to publish its fingerprint
  # all read as retired under that rule, and deleting on it would empty the cache out from under the
  # processes still using it — from inside a resolve, with no way to notice. Reclaiming it properly
  # needs a persisted registry of fingerprints with a last-seen stamp, at which point "retired" is a
  # queryable fact instead of an inference; that is a table this slice would have to invent, and the
  # 90-day window already reclaims these rows, merely a quarter late. Named here so a later cycle
  # finds the analysis rather than re-deriving it.
  #
  # == What the candidate scan costs, measured rather than argued from the schema
  #
  # `index_embedding_cache_entries_on_updated_at` exists and the migration says it was added for
  # this sweep — but an index definition does not determine a plan, so it was EXPLAINed rather than
  # cited (SPGD-273 P1). Probed in the test database at 2,100 rows / 18MB with 100 of them expired,
  # after `ANALYZE`, which is the steady-state shape: the window expires ~1/90th of the table per
  # day, so the reclaimable set is a small fraction of a large one.
  #
  #   -> Limit
  #        -> Bitmap Heap Scan on embedding_cache_entries
  #             Recheck Cond: (updated_at < '...')
  #             -> Bitmap Index Scan on index_embedding_cache_entries_on_updated_at
  #                  Index Cond: (updated_at < '...')
  #
  # The window predicate lands in the **`Index Cond`** and not in a post-`Filter`, which is the half
  # worth certifying: the candidate set is FOUND THROUGH the index rather than by reading the table
  # and discarding rows. That is the whole of what the index buys here — it is worth having because
  # of what it does not read, not because each row it skips would have been costly.
  #
  # ⚠️ **It is NOT that this table is expensive per row to read.** The vector lives out of line (see
  # {DELETE_BATCH_SIZE} for the storage measurement), so the heap tuple is a 168-byte stub and the
  # sequential alternative would scan those, not 6KB rows. {#delete_batch}'s subquery selects only
  # `id` under a predicate on `updated_at` and never detoasts anything, so the vector's width does
  # not enter this plan's cost at all. The index is the right plan; this is the reason it is.
  #
  # ⚠️ **The OUTER half of the statement is the planner's business and nothing here asserts it.** At
  # this size it chose a `Hash Semi Join` over a `Seq Scan` to match the bounded id list, which is
  # the correct choice on 2,100 rows and may well not be the one it makes on a table large enough
  # for this sweep to matter. That is a cost tiebreak decided by resident statistics rather than a
  # strategy this query forces, so it is recorded here and deliberately left unpinned — an example
  # asserting it would be a claim about Postgres's discretion rather than about this class
  # (SPGD-273 P7a/P7d), and would go red on seed and suite ordering. What the spec pins instead is
  # the shape this class does control: one statement per batch, bounded inside the statement.
  class EmbeddingCachePruner
    # How many rows one DELETE may remove. Deliberately a fifth of
    # `Ingest::ObservationPruner::DELETE_BATCH_SIZE`, which is 10,000, because the rows are not
    # comparable: a `spec_observations` row is a few hundred bytes and one of these is ~8.5KB on
    # disk. Almost none of that is in the heap, and the distinction matters to every other claim
    # made about this table.
    #
    # ⚠️ Every figure below that scales with the sibling's batch is derived from THAT CONSTANT, not
    # from this sentence. A previous revision said "a tenth", and a later correction pass trusted
    # the adjacent prose over the constant and doubled a figure at {MAX_BATCHES_PER_RESOLVE}'s
    # ceiling. Re-resolve `Ingest::ObservationPruner::DELETE_BATCH_SIZE` before touching a number
    # here.
    #
    # == Where a row actually lives, MEASURED rather than inferred from the column width
    #
    # ⚠️ **Measured on `vector(1536)`, which this table no longer uses.** The 2026-08-17 migration
    # moved `embedding` to `halfvec(1024)` — 2 bytes per element rather than 4, and 1024 of them
    # rather than 1536, so the datum is 2,052 bytes where it was 6,148. It is still past
    # `TOAST_TUPLE_THRESHOLD` and still stored out of line, so the SHAPE of everything below holds
    # and the batch size does not have to move; the figures do. Roughly a third of the TOAST, about
    # two chunks per row rather than four, and a heap tuple unchanged at 168 bytes because the
    # pointer that replaces the vector is the same 18 bytes either way. **Re-measure before quoting
    # a number from here.**
    #
    # `vector(1536)` is 1536 float4s — 6,148 bytes with its header — which is far past
    # `TOAST_TUPLE_THRESHOLD`, so the column is stored OUT OF LINE. On `embedding_cache_entries`,
    # `pg_attribute.attstorage` for `embedding` is `e` (EXTERNAL: out-of-line and NOT compressed)
    # and `pg_class.reltoastrelid` is populated. What remains in the heap is a stub — `id`, two
    # timestamps, `text_digest`, `provider_fingerprint`, and an 18-byte TOAST pointer.
    #
    # Measured on a faithful reproduction of that table (identical DDL and `attstorage`, the
    # then-production `openai:text-embedding-3-small` fingerprint, a real 64-char digest), at exactly
    # this batch size, after `VACUUM ANALYZE`:
    #
    #   heap tuple           168 bytes exactly (`pageinspect.heap_page_items.lp_len`)
    #   heap density         47 rows on a full 8KB page
    #   TOAST               exactly 4 chunks per row (1,996 x 3 + 160 = 6,148)
    #   2,000 rows           ~16MB on disk: 344KB of heap, ~15.9MB of TOAST
    #
    # ⚠️ **A previous revision of this comment said ~6KB rows put roughly ONE row on a heap page,
    # and every storage figure in this file was derived from that.** It is false — the width never
    # reaches the heap — and it understated the figures, because it also missed that TOAST chunking
    # costs more than the logical bytes (4 chunk tuples, ~8.1KB, to store 6,148 bytes).
    #
    # == What the constant rests on, which is unchanged
    #
    # The batch is ~16MB of dead tuples per statement, the great majority of it in the TOAST
    # relation rather than the heap — a DELETE reclaims both. A batch sized like the sibling's
    # 10,000 would be ~81MB in ONE statement, which is a long lock and a large WAL record for
    # housekeeping nobody asked for. Note what that comparison is and is not: it is the SAME 10,000
    # rows this class's own ceiling reclaims (see {MAX_BATCHES_PER_RESOLVE}, which is why the figure
    # there is also ~81MB), spread over five short statements instead of one long one. The total
    # bytes are identical; what the smaller batch buys is the lock and the WAL record, not less
    # work. That argument is indifferent to WHERE the bytes live, which is why the correction above
    # moves the numbers and not this value.
    DELETE_BATCH_SIZE = 2_000

    # How many of those statements one resolve may issue. With the batch size above this is the
    # per-invocation ceiling — 10,000 rows, ~81MB measured on the same probe — that makes the
    # convergence paragraph true.
    #
    # Stated against the design point rather than picked round: 20,000 rows is one cold start of a
    # 20,000-example suite, so one resolve reclaims half of one and a delivery of four shards
    # reclaims two — against arrivals bounded, in steady state, at 1/90th of a cold start per day by
    # the window itself. The backlog is walked down with slack, and the ceiling is what keeps the
    # first invocation after a long accumulation from being an unbounded sweep.
    MAX_BATCHES_PER_RESOLVE = 5

    def self.prune = new.prune

    # @return [Integer] how many rows this invocation reclaimed. Zero on every deployment whose
    #   oldest entry is younger than the window, which is every deployment until it has been
    #   caching for 90 days.
    def prune
      deleted = 0

      MAX_BATCHES_PER_RESOLVE.times do
        batch = delete_batch
        deleted += batch
        # A short batch means the backlog is exhausted, so stop rather than spending the rest of the
        # ceiling on statements that would delete nothing. A FULL batch means there may be more, and
        # the ceiling is what stops this loop being unbounded.
        break if batch < DELETE_BATCH_SIZE
      end

      deleted
    end

    private

    # One statement: `DELETE ... WHERE id IN (SELECT id ... LIMIT n)`. The inner LIMIT is what bounds
    # it — `delete_all` on a `LIMIT`ed relation is not something Postgres accepts directly, so the
    # bounded select of primary keys is nested inside the delete rather than run as its own round
    # trip. Deleting by `id` also means the outer statement locks exactly the rows it names.
    #
    # The candidate set is {EmbeddingCacheEntry.expired} rather than a second spelling of the window,
    # so the rule this enforces and the rule the read enforces cannot drift apart — and so this reads
    # `updated_at`, which is the column the window is a bound on and the only one an
    # expired-then-re-embedded entry can move. Re-deriving it here as `created_at` would delete rows
    # the `upsert_all` had just revived and that `.vectors_for` was serving.
    def delete_batch
      doomed = EmbeddingCacheEntry.expired.limit(DELETE_BATCH_SIZE).select(:id)

      EmbeddingCacheEntry.where(id: doomed).delete_all
    end
  end
end
