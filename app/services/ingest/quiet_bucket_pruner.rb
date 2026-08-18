# frozen_string_literal: true

module Ingest
  # Drains ONE quiet bucket of the ingesting repository per invocation, which is the half of
  # `SpecObservation::BRANCH_RETENTION_RUNS` {Ingest::ObservationPruner} cannot reach on its own.
  #
  # That class is handed a run and bounds the bucket that run is on. Its only caller is the write
  # path, so a bucket converges while it is being written to and stops the moment it stops
  # receiving runs — and on the measured repository, 46,000 runs across 2,001 branches, nearly all
  # of those branches are merged `feature/*` that will never see another POST. Their history sat
  # permanently outside the one rule that bounds this table. This class is what visits them.
  #
  # == The reach it adds, stated exactly
  #
  # After the current-branch prune, one ingest additionally drains one OTHER bucket of the SAME
  # repository. So a repository still receiving runs anywhere walks its whole backlog down
  # monotonically, one bucket per delivery, without a scheduler and without a recurring job. What
  # is still out of reach is a repository that has stopped ingesting ALTOGETHER — nothing triggers
  # this for it either. That remainder is different in kind from the one it replaces: it is
  # STATIC rather than growing, because the same silence that stops the drain stops the writes.
  #
  # The repository boundary is hard. An ingest never touches a second repository's rows, for the
  # same reason `ObservationPruner` never crosses one: the candidate set is qualified by
  # `repository_id` and there is no path that widens it.
  #
  # == ⭐ Selection is what makes this converge, and the naive probe does not
  #
  # `ObservationPruner` deletes observations and never deletes a `TestRun` row. So *"this bucket
  # has runs older than the window"* stays true FOREVER, including after the bucket has been
  # drained empty. A selection built on that predicate — "the bucket with the oldest expired run"
  # — re-selects the same emptied bucket on every subsequent ingest and never advances. It would
  # look like it was working, and it would visit exactly one bucket ever.
  #
  # So the predicate here counts runs that STILL HOLD ROWS:
  #
  #   the buckets of this repository, other than the ingesting one, having more than
  #   `SpecObservation::BRANCH_RETENTION_RUNS` runs that still carry an observation
  #
  # That is exact rather than heuristic in both directions. The rule retains N runs of the bucket,
  # whichever N are most recent; so a bucket with M > N observation-bearing runs has at least
  # M - N of them outside the retained window, and a selected bucket is GUARANTEED to yield work.
  # And draining moves M down toward N, so a drained bucket drops out of the candidate set by
  # itself — no cursor, no rotation state, no "last visited" column to keep. Progress across
  # buckets is a property of the predicate rather than of a bookkeeping row.
  #
  # It under-selects rather than over-selects: a bucket whose only expired rows hang off runs
  # inside a set of N that is itself sparsely populated is not picked. That is the right direction
  # for opportunistic work — it never spends an ingest's ceiling on a bucket that turns out to
  # have nothing.
  #
  # ⚠️ What it declines is reached again only for a LIVE bucket, the moment that bucket grows past
  # the rule. A merged `feature/*` one — the population this class exists for — never grows again
  # by definition. So a quiet bucket holding expired rows across `<= BRANCH_RETENTION_RUNS`
  # row-bearing runs (sparse histories: runs recorded with no examples, runs predating the
  # observation recorder) is out of reach PERMANENTLY, not until it grows. That is a second honest
  # remainder alongside the stopped-ingesting-altogether one above, and the same shape as it:
  # small, static, and named here rather than papered over.
  #
  # == The probe is bounded, and by WHAT is the part worth stating
  #
  # `index_test_runs_on_repository_id_and_branch_and_created_at` (`[repository_id, branch,
  # created_at, id]`) delivers this repository's runs already grouped by branch, so the aggregate
  # is a streaming `GroupAggregate` over one index range rather than a hash of the table, and
  # `ORDER BY branch LIMIT 1` rides that same ordering — the scan STOPS at the first qualifying
  # bucket instead of aggregating the repository. The `EXISTS` is an index probe against
  # `index_spec_observations_on_test_run_id`; `spec_observations` is never scanned, only probed by
  # `test_run_id`, and never for a repository other than this one.
  #
  # The honest worst case is the converged one — every bucket already at the rule, so nothing
  # short-circuits the scan and it walks this repository's index range to the end and finds
  # nothing. That is bounded by the repository's own run count and by nothing about the size of
  # either table.
  #
  # ⚠️ It is also the EXPENSIVE direction per row, and the seeded `EXPLAIN` on this change says
  # so: 7,140 of the 9,520 scanned runs PASS the semi-join. That is not a fixture accident, it is
  # what convergence MEANS — the rule retains `BRANCH_RETENTION_RUNS` runs per bucket WITH their
  # rows and empties only what is beyond them, so the passing count is exactly
  # `quiet_buckets * BRANCH_RETENTION_RUNS` and the fraction of probes coming back NEGATIVE is
  # `1 - BRANCH_RETENTION_RUNS / runs_per_bucket`. That fraction SHRINKS on the short merged
  # `feature/*` buckets this class exists to visit. So the `EXISTS` is predominantly a POSITIVE
  # index probe, and the measured cost is 19 ms for 9,520 runs at 75% of them qualifying — which
  # is affordable on its own terms and does not need a cheaper story than the one that is true.
  # (`Heap Fetches: 7140` on that plan is partly an unvacuumed visibility map, but it is also one
  # heap touch per QUALIFYING row — the same 75%.)
  #
  # ⚠️ Extrapolated to the repository named at the top of this comment, which is the one this
  # class was built for: 46,000 runs is ~4.8x the seeded range, so its converged steady state
  # costs on the order of 90 ms of probe. PER INVOCATION, which is per SHARD — a four-shard run
  # pays it four times, ~370 ms, for housekeeping the client did not ask for and on which it will
  # usually find nothing. That is the cost of SUCCESS: this class drives a repository into the
  # state where its own probe is most expensive and least productive. Judged affordable against an
  # ingest that is already a multi-statement write, and it is the price of having no scheduler —
  # but 90 ms is the figure to quote for that repository, not the seeded 19 ms, and this is the
  # first number to re-measure if this path ever gets tight.
  #
  # Ordering by `branch` rather than by "oldest first" is deliberate. Oldest-first would need
  # `MIN(created_at)` across every group before it could pick one, which forfeits the
  # short-circuit and makes the query cost the repository on EVERY ingest instead of only on a
  # converged one. Branch order is the order the index already has, and it costs nothing. Which
  # bucket goes first is not a property worth paying for: every candidate is over the rule, so any
  # of them is progress, and the ones not picked are picked by the next delivery.
  #
  # On the literal wording of "selection makes progress across buckets": `LIMIT 1` in branch order
  # re-selects the SAME bucket on successive ingests until it falls under the rule, which at this
  # ceiling can take several deliveries, while another bucket is still over it. Within-bucket
  # progress precedes across-bucket progress. That is still convergence, and it is not the failure
  # the requirement is aimed at — that one is finding 2's stall, where selection re-picks a bucket
  # it has ALREADY emptied and advances never. The predicate rules it out from both ends: a
  # selected bucket is guaranteed to yield at least one delete, so every invocation moves M down,
  # and a bucket that reaches the rule leaves the candidate set for good. The ordering is a queue
  # discipline, not a liveness property.
  #
  # == Bounded per invocation, on its own ceiling
  #
  # `MAX_BATCHES_PER_INGEST` here is separate from and smaller than the current-branch half's. One
  # ingest's total delete work is
  # `ObservationPruner::DELETE_BATCH_SIZE * (ObservationPruner::MAX_BATCHES_PER_INGEST +
  # MAX_BATCHES_PER_INGEST)` rows, and the ceiling is stated PER INVOCATION rather than per
  # logical run: a sharded run POSTs once per shard, so a four-shard run drains four quiet buckets
  # and pays four times this ceiling. That is acceptable convergence behaviour — the buckets are
  # different ones, since each drained bucket leaves the candidate set — but it is why the number
  # here is smaller than its sibling's: this is backlog work on rows the delivery did not create,
  # and it should stay the smaller half of what an ingest pays for housekeeping.
  #
  # Called AFTER the ingest transaction commits, outside `run.lock!`, for the reason
  # `ObservationPruner` states at length: lengthening that hold is how this path deadlocked before.
  #
  # == This raises, and the CALLER contains it
  #
  # Deliberately no internal rescue, on the precedent {Ingest::EmbeddingCachePruner} set — *"the
  # policy belongs to the caller that knows what it is in the middle of"* — with containment at
  # `Ingest::RunRecorder#drain_quiet_bucket` exactly as `IdentityResolver#reclaim_expired_cache`
  # contains its sibling.
  #
  # ⚠️ The containment is the OPPOSITE of the current-branch half's, and the asymmetry is the
  # point. `ObservationPruner` is allowed to fail the ingest because it bounds the rows this
  # delivery just wrote, and a rule that cannot keep up with its own write path is the last thing
  # that should fail quietly. This half touches rows an OLDER delivery wrote, which the client
  # never asked about and cannot act on, so a failure here must not turn a committed ingest into a
  # 500. It surfaces through `Rails.error.report` instead — loud in the error reporter, invisible
  # in the response.
  class QuietBucketPruner
    # How many bounded deletes one invocation may spend on the quiet half. Smaller than
    # `ObservationPruner::MAX_BATCHES_PER_INGEST` on purpose; see the ceiling section above.
    MAX_BATCHES_PER_INGEST = 2

    def self.drain(run) = new(run).drain

    def initialize(run)
      @repository_id = run.repository_id
      @branch = run.branch
    end

    # @return [Integer] how many rows this invocation deleted. Zero when this repository holds no
    #   other bucket over the rule, which is the steady state a converged repository sits in.
    def drain
      bucket = quiet_bucket_over_the_rule
      return 0 if bucket.empty?

      ObservationPruner.prune_bucket(
        repository_id: @repository_id, branch: bucket.first, max_batches: MAX_BATCHES_PER_INGEST
      )
    end

    private

    # One statement. `pluck` on a one-row limit rather than `pick`, because the answer is a branch
    # name and `nil` is a REAL branch here — the anonymous bucket, which is as eligible for this as
    # any named one. `pick` would flatten "no candidate" and "the branch-less candidate" into the
    # same `nil` and silently skip the bucket a laptop's runs land in.
    #
    # `IS DISTINCT FROM` and not `!=`, for the same reason: with a named `@branch`, plain `!=`
    # drops the `NULL` rows by three-valued logic and the anonymous bucket becomes unreachable
    # from every named branch's ingest.
    #
    # @return [Array<String, nil>] the one branch to drain, or empty when there is none.
    def quiet_bucket_over_the_rule
      TestRun
        .where(repository_id: @repository_id)
        .where("test_runs.branch IS DISTINCT FROM ?", @branch)
        .where("EXISTS (SELECT 1 FROM spec_observations WHERE spec_observations.test_run_id = test_runs.id)")
        .group(:branch)
        .having("COUNT(*) > ?", SpecObservation::BRANCH_RETENTION_RUNS)
        .order(:branch)
        .limit(1)
        .pluck(:branch)
    end
  end
end
