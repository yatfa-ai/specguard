# frozen_string_literal: true

# Phase 2's synchronous half: accept one CI run, validate it, record the run's counts, and answer
# `202 Accepted` immediately. Nothing here blocks on embedding — that is asynchronous by design,
# so anything reading the embeddings will trail a run that just landed.
#
# One request is one *shard*, not necessarily one run: a sharded suite POSTs once per process, and
# `Ingest::RunRecorder` is what folds those back into the single `TestRun` they came from.
class Api::V1::IngestsController < Api::BaseController
  def create
    payload = Ingest::Payload.new(request.request_parameters)

    return render_bad_request(payload.errors) unless payload.valid?

    test_run = Ingest::RunRecorder.record(current_repository, payload.test_run_attributes,
                                          shard_id: payload.shard_id, specs: payload.specs)

    render json: {
      test_run_id: test_run.id,
      # These are the whole CI run's totals, not this shard's own slice — the row *is* the run
      # (see `Ingest::RunRecorder`), and after a re-run they are the run's *current* numbers
      # rather than a running tally, because the run's counts are derived from its shards rather
      # than accumulated. For an unsharded run, which is every run with no `ci_run_id`, the run
      # and the shard are the same thing and so are the numbers.
      total_specs: test_run.total_specs_count,
      annotated_specs: test_run.annotated_specs_count,
      # A 0–1 fraction, per the SpecGuard API Reference. The dashboard renders the same number as a
      # percentage via `TestRun#annotated_ratio`; the API and the UI differ in unit on purpose,
      # so neither side has to guess which one it is holding.
      annotated_ratio: test_run.annotated_fraction,
      embedding_status: enqueue_embeddings(test_run, payload.annotated_specs)
    }, status: :accepted
  end

  private

  # The named seam slice 3 (SPGD-84) fills in: it will enqueue the embed + upsert job for each
  # annotated spec and report "queued". Until that job class and the queue behind it exist there
  # is nothing to schedule, so this reports "pending" and enqueues nothing.
  #
  # Reporting "queued" from here would be the cheapest possible lie: the client would read a
  # success value for work that was never scheduled, and would keep reading it for as long as the
  # seam stays empty. Deliberately no reference to a job constant either — eager loading a
  # constant that does not exist yet would take the whole endpoint down at boot.
  def enqueue_embeddings(_test_run, _annotated_specs)
    "pending"
  end
end
