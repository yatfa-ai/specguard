# frozen_string_literal: true

# Phase 2's synchronous half: accept one CI run, validate it, record the run's counts, and answer
# `202 Accepted` immediately. Nothing here blocks on embedding — that is asynchronous by design
# (`Ingest::IdentityResolutionJob`), so anything reading the embeddings will trail a run that just
# landed.
#
# One request is one *shard*, not necessarily one run: a sharded suite POSTs once per process, and
# `Ingest::RunRecorder` is what folds those back into the single `TestRun` they came from.
class Api::V1::IngestsController < Api::BaseController
  # THIS ENDPOINT NEEDS A REPOSITORY, and says so rather than discovering it. `current_repository`
  # is passed straight into the recorders below on the strength of "authentication resolved one" —
  # a `sgu_` user key reaching that line would arrive as `nil` and be recorded as telemetry against
  # nothing, or blow up as a 500. It is refused at the door instead. See `Api::BaseController`.
  accepts_repository_credential

  def create
    payload = Ingest::Payload.new(request.request_parameters)

    # The refusal, and the one record it leaves behind.
    #
    # Recorded BEFORE the render and never after it: `render_bad_request` returns, so anything
    # placed below this line would not run. The row is written for the authenticated family only,
    # which is exactly what reaching this line means — `authenticate_api_key!` has already resolved
    # `current_repository`, and a request that failed to authenticate returned a 401 from the
    # `before_action` without ever arriving here. A 401 therefore writes nothing, because there is
    # no repository to attribute it to (see `IngestRejection`).
    #
    # The response is untouched by this: `render_bad_request` is handed the same `payload.errors`
    # it always was, and the recorder cannot change the status or the body — it reports its own
    # failures to `Rails.error.report` and returns, on the reasoning in
    # `Ingest::RejectionRecorder`. A request that is being refused for its payload must not start
    # 500ing because of bookkeeping the client never asked for.
    unless payload.valid?
      Ingest::RejectionRecorder.record(current_repository, payload.errors,
                                       user_agent: request.user_agent)

      return render_bad_request(payload.errors)
    end

    test_run = Ingest::RunRecorder.record(current_repository, payload.test_run_attributes,
                                          shard_id: payload.shard_id, specs: payload.specs)

    # Scheduled before the response is built rather than from inside the hash literal below: this
    # writes to the queue and can fail, and a side effect with a failure mode does not belong in a
    # value position where it reads as one more field being looked up.
    embedding_status = enqueue_embeddings(test_run, payload.specs)

    # ONE additional aggregate on the ingest path, and it is a deliberate cost rather than one
    # discovered in review. Everything above renders off `test_run.*`, which `Ingest::RunRecorder`
    # returns with the run's derived totals already loaded; per-example identity is not among them,
    # because it is a fact about the ROWS this run wrote and not about the counts its shards
    # reported. Both figures below come out of this single call — never two queries for two
    # numbers that have to agree.
    coverage = SpecObservation.coverage_in(test_run)

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
      # HOW MANY OF THIS RUN'S ROWS CARRY AN `id`, AND THE DENOMINATOR THAT MAKES THAT A FRACTION.
      #
      # `example_id` is the upsert key (`Ingest::ObservationRecorder`, `unique_by: %i[test_run_id
      # example_id]`) and it arrives unvalidated, so a payload omitting every id is accepted and
      # used to return a body byte-identical to one sending them all. For an ANONYMOUS SLICE
      # (`ci_run_id` present, `shard_id` nil) an id-less redelivery has nothing to conflict with
      # and doubles the run's rows — that shape only, per that class's "the three shapes, and the
      # one that has no answer": a named shard is replaced by the delete on `test_run_shard_id`
      # regardless of ids, and without a `ci_run_id` every POST is its own run. What the ids buy a
      # named shard is the ability to REPLACE a re-delivered slice's rows rather than append them,
      # and they are the only thing that would protect those slices if the `shard_id` were ever
      # dropped. They are NOT what carries an example across runs: `example_id` is run-local by
      # construction (`SpecObservation`, "The key is run-local, and says so" — positional, unique
      # within a run, `unique_by: %i[test_run_id example_id]` and nothing wider). Cross-run identity
      # is `SpecIdentity`'s, resolved from the row's TEXT via `Ingest::IdentityResolver` — which
      # never reads `example_id` — so an id-less run still gets it, `Ingest::Payload#validate_name`
      # requiring a name or an intent on every spec. The fix is client-side, and these two operands
      # are what let a client see that it needs to apply it.
      #
      # THE TWO ARE ONE GRAIN AND THE PAIR IS THE POINT. Both are counted over the rows this run
      # wrote to `spec_observations`; the shortfall is `recorded_specs - identified_specs` and it
      # is NEVER `total_specs - identified_specs`. `total_specs` is the whole run's suite size,
      # re-derived by SUM over `test_run_shards` from what the client REPORTED, while these count
      # rows — and the two legitimately disagree, because a payload repeating an `id` contributes
      # one row for it. Subtracting across the two grains invents a shortfall for a producer that
      # sent every id it has.
      #
      # Integers, and `0` rather than `null` on a run that recorded nothing: "no row carried an id"
      # is a measured statement, unlike `annotated_ratio`, which is null only because 0/0 is
      # undefined. Operands, not a verdict — the client draws the conclusion.
      recorded_specs: coverage.fetch(:recorded_count),
      identified_specs: coverage.fetch(:identified_count),
      embedding_status: embedding_status
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
