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
  # == No retry policy, deliberately
  #
  # No `retry_on`, no `discard_on`. SPGD-362 hands both to SPGD-72 by name, along with partial-failure
  # observability, and a policy guessed here would be the thing that work has to undo first. What is
  # safe to say now is that a re-run is harmless: the resolver's work list is the run's *unresolved*
  # observations, so re-running this job re-does only what did not land.
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
