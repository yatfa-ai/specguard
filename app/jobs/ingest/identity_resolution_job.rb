# frozen_string_literal: true

module Ingest
  # The asynchronous half of `POST /api/v1/ingest`: gives every example the run delivered a durable
  # {SpecIdentity}. Enqueued by `Api::V1::IngestsController#enqueue_embeddings`, which is what makes
  # that seam able to report `"queued"` truthfully.
  #
  # Thin on purpose — {Ingest::IdentityResolver} holds the work, and every question about where it
  # runs, why it is out of the ingest transaction, and how two of these overlapping stay idempotent
  # is answered on that class.
  #
  # == No retry policy, and it is a finding rather than a deferral
  #
  # No `retry_on`, no `discard_on`. `retry_on EmbeddingGenerator::Error` is the obvious policy here
  # and it would **never fire**: {Ingest::IdentityResolver#embed} rescues that class at the single
  # call site and returns nil, so the error is consumed before ActiveJob can see it and this job
  # always completes *successfully* having resolved zero rows. That rescue is deliberate — one
  # unembeddable example must not abandon the other 19,999 — so the retry belongs in the work list,
  # and that is where it now is: the resolver sweeps the repository's earlier failed rows alongside
  # this run's, bounded by `SpecObservation::EMBED_RETRY_WINDOW` and
  # `Ingest::IdentityResolver::RETRY_SWEEP_LIMIT`.
  #
  # What is left for a job-level policy to cover is everything that is NOT an embedding failure — a
  # database blip, a deploy mid-job — which raises out of `perform` and lands in Solid Queue's failed
  # executions. **Nothing re-runs this job for those.** There is no `retry_on` (`ApplicationJob`'s
  # are commented out), no sweeper in `config/recurring.yml`, and the only `perform_later` in the
  # application is per-run from the ingest request — so a run that simply finished delivering is
  # never redelivered and its job is never re-enqueued.
  #
  # What re-does the work is the NEXT INGEST of the same repository, which is the same mechanism the
  # failure backlog already uses: the resolver's cross-run sweep reads the rows this job never
  # reached — unresolved, unstamped, and past `SpecObservation::EMBED_ATTEMPT_GRACE` — and attempts
  # them under the same budget. Re-doing only what did not land is a property of the WORK LIST, and
  # it holds for whatever walks it; what it never was, and what this paragraph used to imply, is a
  # reason to expect this job to be walked again.
  #
  # A run that no longer exists is not an error. Between the enqueue and the dequeue its repository
  # may have been deleted, which takes the run with it; there is nothing to resolve and nothing to
  # report.
  #
  # == Why one run's jobs run one at a time
  #
  # `Api::V1::IngestsController#enqueue_embeddings` enqueues one of these per POST, and one POST is
  # one SHARD, not one run — so an N-shard delivery schedules N jobs over the same work list. The
  # resolver survives that overlap (see its "Idempotency" section) but nothing ever PRICED it, and
  # the price is the whole suite: the run-scoped list is uncapped, so each overlapping job pays an
  # embed + ANN lookup + upsert for every row the others have not yet claimed — 20,000 of them at the
  # roadmap's design point on a first or changed run.
  #
  # The honest bound on that waste is **`min(shard_count, worker threads)`, not N**. `config/queue.yml`
  # runs `threads: 3` with one process by default, so at most three of the N jobs are ever in flight
  # together; the rest queue behind and find the rows already resolved, which is cheap. Three is still
  # the deployment's entire worker pool, so a sharded delivery resolving itself three times also stops
  # everything else from progressing while it does.
  #
  # `limits_concurrency` keyed on the run collapses that to one. The other jobs are **blocked, not
  # discarded** — `on_conflict:` stays at its `:block` default deliberately, because discarding a
  # shard's job would silently strand every row that shard delivered until some later ingest's
  # cross-run sweep noticed them. Each blocked job still runs, and finds only what is left, because
  # the job ahead of it flushed its pages. Releasing the next one is the gem's job
  # (`SolidQueue::ClaimedExecution#unblock_next_blocked_job`).
  #
  # The key derives from the ARGUMENT so it scopes to the run: the composed key is
  # `"Ingest::IdentityResolutionJob/<test_run_id>"`, leaving different runs — and therefore different
  # repositories — fully parallel. A constant key here would serialize identity resolution across the
  # entire deployment.
  #
  # This makes overlap RARE, not impossible (semaphore expiry, a redelivered shard, two runs of one
  # repository sharing the failure backlog), so the resolver's three overlap-survival mechanisms — the
  # `claim_identity` upsert convergence, `SIGHTING_NOT_OLDER`, and `write_page`'s deadlock retry — are
  # all still load-bearing and none of them may be deleted on the strength of this.
  class IdentityResolutionJob < ApplicationJob
    queue_as :default

    # `duration:` bounds a STUCK semaphore, not an expected runtime: it is how long the dispatcher
    # waits before assuming the holder died and releasing a blocked job anyway. It must therefore
    # exceed the worst-case resolve wall clock — a 20,000-row resolve is minutes of embed + ANN work,
    # and SolidQueue's 3-minute default would expire mid-resolve and quietly restore the overlap this
    # exists to remove. Hours, so expiry means "something is wrong", never "this run is large".
    limits_concurrency to: 1, key: ->(test_run_id) { test_run_id }, duration: 6.hours

    def perform(test_run_id)
      run = TestRun.find_by(id: test_run_id)
      return if run.nil?

      Ingest::IdentityResolver.resolve(run)
    end
  end
end
