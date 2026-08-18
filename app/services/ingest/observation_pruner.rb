# frozen_string_literal: true

module Ingest
  # Enforces `SpecObservation::BRANCH_RETENTION_RUNS` — the only thing that deletes a row from
  # `spec_observations` for AGE, and the other half of the roadmap's *"retain outcome/duration
  # across runs **with a stated retention rule**"*. Before this class the rule was retention
  # by omission: {Ingest::ObservationRecorder} deletes only the delivery it is replacing, and
  # rows otherwise left the table only when their repository or their run was destroyed.
  #
  # == Keyed per (repository, branch), which is the whole design
  #
  # The obvious rule — "keep the last N runs of this repository" — is worse than no rule at all.
  # Recency across a repository is INTERLEAVED: `Api::V1::RepositoriesController
  # #serialized_branches` records that on a repository whose CI reports on every PR, all ten most
  # recent runs are routinely `feature/*` and the trunk never appears among them. A
  # repository-wide bound would therefore evict `main`'s history FIRST — and `main` is what every
  # cross-run read is anchored to. So the window is per branch: N runs of `main`, N runs of each
  # `feature/*`, each bucket bounded on its own and unable to evict any other.
  #
  # A run with `branch: nil` is its own bucket, per repository. *"The anonymous runs of every
  # machine are not one branch"* (`serialized_branches` again) — so they neither evict a named
  # branch's history nor are evicted by it, and `branch IS NULL` is a bucket boundary here exactly
  # as it is a series boundary in `Repository#suite_size_trajectory`.
  #
  # Bounded by ROWS and never by a date window, the choice `Repository::TRAJECTORY_LIMIT` argues
  # for one layer up: a repository whose CI went quiet for a month has not stopped wanting its
  # history, and a time-based rule would delete it for being idle.
  #
  # == Two steps, because the branch is not on the row
  #
  # `spec_observations` has no `branch` column — the branch is reached through `test_runs` — so
  # this selects the run ids on the branch first and deletes observations BY `test_run_id`.
  # Neither step needs a migration: `index_test_runs_on_repository_id_and_branch_and_created_at`
  # (`[repository_id, branch, created_at, id]`) serves the boundary lookup, and
  # `index_spec_observations_on_test_run_id` serves the delete.
  #
  # `test_runs` itself is UNTOUCHED, and so are both of a run's counters. A pruned run keeps its
  # row, its `total_specs_count` and its `annotated_specs_count` — those are derived from
  # `test_run_shards`, not from these rows — so the suite-size trajectory, which reads
  # `test_runs` plus a shard-count subquery and touches this table nowhere, is unaffected at any
  # depth. What a pruned run loses is the per-EXAMPLE detail: the slowest-examples and
  # heaviest-files panels of a run that far back.
  #
  # == What converges, and what does not
  #
  # One POST must not attempt an unbounded delete: the first ingest after this ships can meet a
  # backlog accumulated over the whole life of a repository, ~920M rows on the measured one,
  # because nothing has ever deleted a row here for age. So the delete is issued in bounded
  # batches with a hard per-invocation ceiling of `DELETE_BATCH_SIZE * MAX_BATCHES_PER_INGEST`
  # rows, and what that buys is CONVERGENCE rather than completeness: an invocation meeting more
  # than its ceiling prunes what the ceiling allows and leaves the rest, and successive ingests
  # ON THAT BRANCH walk that branch's backlog down to the rule.
  #
  # ⚠️ The branch qualifier is the whole of the claim, not a footnote to it. An invocation of THIS
  # class reaches only the rows of the branch of the run it was handed, and its only caller is the
  # write path — so a bucket converges while it is being written to and stops converging the moment
  # it stops receiving runs. The measured repository is 46,000 runs across 2,001 branches, and most
  # of those are merged `feature/*` that will never see another POST.
  #
  # That used to be the end of the sentence, and it no longer is. {Ingest::QuietBucketPruner} runs
  # beside this class on the same write path and drains ONE other bucket of the same repository per
  # ingest, selected on a predicate that provably advances across buckets rather than re-visiting
  # one. So a merged `feature/*` branch IS walked down now — not by the ingest on that branch,
  # which will never come, but by the ingests still arriving on whatever branches the repository is
  # live on. What this class bounds is future growth on the live bucket; what the pair of them
  # bounds is the repository.
  #
  # What remains out of reach is smaller and different in kind: a repository that has stopped
  # ingesting ALTOGETHER. Neither half has a trigger for it, because both hang off the write path
  # and there is still no scheduler and no recurring job. Its tail is therefore STATIC rather than
  # growing — the silence that stops the drain is the same silence that stops the writes — which
  # is the honest remainder rather than the original one. Provision for neither half as a backfill.
  #
  # The ceiling is stated against the design point rather than picked round: 20,000 examples is
  # one run, so 50,000 rows per delivery is two and a half runs' worth of history removed per
  # delivery against one run's worth arriving — and a sharded run POSTs once per shard, so a
  # four-shard run prunes four times. A live branch reaches steady state and holds it with slack.
  #
  # The loop cannot stall, and the reason is NOT that a batch takes the oldest rows it can reach:
  # `delete_batch` issues no `ORDER BY`, and WHICH of the expired rows a batch reaches is the
  # planner's business. It is that every row in the candidate set is already past the window, so
  # any batch is progress — the work left for the next invocation is strictly smaller by exactly
  # what this one deleted, whichever rows those were.
  #
  # == Outside the ingest transaction, on purpose
  #
  # Called AFTER the ingest transaction commits, never inside it. `Ingest::RunRecorder#record`
  # holds `run.lock!` across its whole insert-and-recompute, and that lock's length is measured
  # and load-bearing (8 concurrent shards, 6 of 8 lost to `PG::TRDeadlockDetected` before the lock
  # moved). This work needs none of that protection — it touches only rows of runs OLDER than the
  # window, which no concurrent delivery is writing — so it must not extend the hold. Both of
  # `RunRecorder`'s paths call it, each after its own commit.
  #
  # == A prune failure fails the ingest, which is a policy choice rather than a default
  #
  # Nothing rescues this call, so a prune that raises turns an ingest whose data ALREADY COMMITTED
  # into a 500. The tail of that deserves naming rather than glossing: the failures this will
  # actually meet are the persistent ones — a `statement_timeout` or a lock wait on a 10,000-row
  # delete against a table this rule arrived too late to have kept small. Persistent means every
  # POST answers 500, for housekeeping the client never asked for, and the client's retry re-runs
  # the whole insert path and dies on the same delete. A prune that cannot keep up is, as this
  # stands, an ingest outage.
  #
  # It is left that way rather than rescued because an ingest is idempotent by construction
  # (derived counters, delete-then-upsert observations), so a retry costs a duplicate delivery of a
  # slice that replaces itself — and because that failure mode IS the table having outgrown the one
  # rule bounding it, which is the last thing that should fail invisibly. The choice is not the
  # two-way one between raising and a bare rescue, though: `Rails.error.report` is a third option
  # available here today (Rails 8, no new dependency, no new seam to invent) that would fail the
  # rule loudly in the error reporter while the ingest still answers 202 for work that genuinely
  # succeeded. Reach for it if the outage risk above stops being an acceptable trade — but that
  # changes what the write path promises a client on a request it accepted, so it belongs to
  # whoever owns that contract rather than being decided quietly inside this class.
  class ObservationPruner
    # How many rows one DELETE may remove. Half a design-point run, so a single statement is a
    # bounded amount of work for the ingest request that pays for it rather than a table sweep.
    DELETE_BATCH_SIZE = 10_000

    # How many of those statements one invocation may issue by DEFAULT, which is what the
    # current-branch half spends. With the batch size above this is the per-invocation ceiling —
    # 50,000 rows — that makes the paragraph on convergence true.
    #
    # A default rather than a constant read straight from the loop, because {.prune_bucket} lets
    # the caller state a smaller one: {Ingest::QuietBucketPruner} spends less of an ingest on
    # backlog work than this class spends on the delivery it was handed. One ingest's TOTAL is the
    # sum of the two, and it is stated per invocation — a sharded run POSTs once per shard.
    MAX_BATCHES_PER_INGEST = 5

    # The current-branch half: the bucket of the run this ingest just wrote. Unchanged in meaning
    # and in failure policy — a raise here still fails the ingest.
    def self.prune(run) = new(repository_id: run.repository_id, branch: run.branch).prune

    # The same delete, aimed at a bucket no run in hand belongs to, on a ceiling the caller states.
    # {Ingest::QuietBucketPruner} owns WHICH bucket and WHY it is safe to pick; all that is
    # delegated here is the boundary-and-batched-delete this class already is, so the two halves
    # cannot drift on what "expired" means.
    def self.prune_bucket(repository_id:, branch:, max_batches: MAX_BATCHES_PER_INGEST)
      new(repository_id: repository_id, branch: branch, max_batches: max_batches).prune
    end

    def initialize(repository_id:, branch:, max_batches: MAX_BATCHES_PER_INGEST)
      @repository_id = repository_id
      @branch = branch
      @max_batches = max_batches
    end

    # @return [Integer] how many rows this invocation deleted. Zero when the branch holds fewer
    #   than `SpecObservation::BRANCH_RETENTION_RUNS` runs, which is every branch of every
    #   repository until it has run that many times.
    def prune
      boundary = oldest_retained_run
      return 0 if boundary.nil?

      deleted = 0

      @max_batches.times do
        batch = delete_batch(boundary)
        deleted += batch
        # A short batch means the backlog is exhausted, so stop rather than spending the rest of
        # the ceiling on statements that would delete nothing. A FULL batch means there may be
        # more, and the ceiling is what stops this loop being unbounded.
        break if batch < DELETE_BATCH_SIZE
      end

      deleted
    end

    private

    # This branch's runs, in this repository. `branch` may be nil, and `nil` here compiles to
    # `branch IS NULL` — the anonymous bucket, scoped to one repository like every other.
    def branch_runs = TestRun.where(repository_id: @repository_id, branch: @branch)

    # The oldest run the rule KEEPS: the Nth most recent on this branch, as `[created_at, id]`.
    # Nil when the branch has fewer than N runs, which is the "nothing to do" case.
    #
    # `(created_at, id) DESC` with `id` breaking the tie, the same total ordering
    # `Repository#previous_test_run_on_branch` and `#suite_size_trajectory` use — a bare
    # `created_at` orders a same-instant pair arbitrarily, and here that would mean the boundary
    # falling either side of two runs ingested in the same second, deleting one of them or not
    # depending on the plan.
    def oldest_retained_run
      branch_runs.order(created_at: :desc, id: :desc)
                 .offset(SpecObservation::BRANCH_RETENTION_RUNS - 1)
                 .pick(:created_at, :id)
    end

    # The runs strictly older than the boundary — a relation, so it is a subquery rather than an
    # id list loaded into Ruby. Strictly `<`, so the boundary run itself is retained: it is the
    # Nth, and N runs are kept.
    def expired_runs(boundary)
      branch_runs
        .where("(test_runs.created_at, test_runs.id) < (?, ?)", boundary.first, boundary.last)
        .select(:id)
    end

    # One statement: `DELETE ... WHERE id IN (SELECT id ... LIMIT n)`. The inner LIMIT is what
    # bounds it — `delete_all` on a `LIMIT`ed relation is not something Postgres accepts directly,
    # so the bounded select of primary keys is nested inside the delete rather than run as its own
    # round trip. Deleting by `id` also means the outer statement locks exactly the rows it names.
    def delete_batch(boundary)
      doomed = SpecObservation.where(test_run_id: expired_runs(boundary))
                              .limit(DELETE_BATCH_SIZE)
                              .select(:id)

      SpecObservation.where(id: doomed).delete_all
    end
  end
end
