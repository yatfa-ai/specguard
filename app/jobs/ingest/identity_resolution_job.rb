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
  class IdentityResolutionJob < ApplicationJob
    queue_as :default

    def perform(test_run_id)
      run = TestRun.find_by(id: test_run_id)
      return if run.nil?

      Ingest::IdentityResolver.resolve(run)
    end
  end
end
