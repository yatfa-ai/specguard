# frozen_string_literal: true

# Phase 2's synchronous half: accept one CI run, validate it, record the run's counts, and answer
# `202 Accepted` immediately. Nothing here blocks on embedding — that is asynchronous by design
# (`Ingest::IdentityResolutionJob`), so anything reading the embeddings will trail a run that just
# landed.
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
      embedding_status: enqueue_embeddings(test_run, payload.specs)
    }, status: :accepted
  end

  private

  # Schedules the work that gives every example a durable identity, and reports whether it actually
  # did. Two values, and the API Reference fixes both: `"queued"` **only** when a job was genuinely
  # enqueued, `"pending"` otherwise. Reporting `"queued"` from a seam that scheduled nothing would be
  # the cheapest possible lie — a success value read for work that never existed — and this method
  # is where that stays true.
  #
  # It is handed the **whole** population rather than `payload.annotated_specs`, because the text
  # that represents a test is not only an intent: `Ingest::SpecSignal` answers for an unannotated
  # example out of its `name`, and passing the annotated slice here would decide — at the caller,
  # silently — that a suite mid-adoption has nothing to embed. That is exactly the cold-start case
  # the platform is for. The filter below is `Ingest::SpecSignal#present?`; the rule itself is not
  # re-derived here.
  #
  # The job is handed the run's id and nothing else. `Ingest::ObservationRecorder` has already
  # written this delivery's examples, intent triple included, so the specs are in the database by the
  # time it runs — and a 20,000-example payload passed as a job argument would be megabytes of JSON
  # in `solid_queue_jobs` on the one path whose design point is exactly that size.
  #
  # `"pending"` here means "nothing to schedule", which is a payload with no spec carrying either an
  # intent or a name. `Ingest::Payload#validate_name` refuses that spec, so in practice this is the
  # empty run — a client POSTing `specs: []`. Saying `"queued"` for it would be the same lie in
  # miniature.
  def enqueue_embeddings(test_run, specs)
    return "pending" unless specs.any? { |spec| Ingest::SpecSignal.for(spec).present? }

    Ingest::IdentityResolutionJob.perform_later(test_run.id)
    "queued"
  end
end
