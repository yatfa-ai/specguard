# frozen_string_literal: true

module Ingest
  # Turns one `POST /api/v1/ingest` into the `TestRun` row it belongs to.
  #
  # For most runs that is a plain `create!` — one process, one POST, one row, exactly as before.
  # The case this class exists for is the other one: a suite large enough that nobody runs it in a
  # single process. Under `parallel_tests`, Knapsack or a CI matrix, each shard loads the formatter
  # and POSTs its own slice of the suite, and every shard carries the same `commit_sha` and
  # `branch`. Creating a row per request therefore produced N rows per run, each with a **split
  # denominator** — a 20,000-example suite landing as four rows of ~5,000 — and
  # `Repository#latest_test_run` picked whichever shard happened to finish last. Annotations are
  # never spread evenly across shards (teams annotate the area they are working on), so the same
  # commit re-run reported a different headline without the suite changing at all.
  #
  # The dashboard could not catch it either: the run was not *stale*, which is the one thing the
  # view warns about — it was *partial*, and honestly attributed to the right commit.
  #
  # == The key is the run, not the commit
  #
  # `ci_run_id` is the client's own CI provider's id for the build (`GITHUB_RUN_ID`,
  # `CI_PIPELINE_ID`, …). Every shard of one run shares it and no second run repeats it, which is
  # why `commit_sha` cannot serve: a re-run and a nightly of the same commit are genuinely two
  # runs and must stay two rows.
  #
  # A run with **no** `ci_run_id` — a laptop `bundle exec rspec`, an unrecognised provider — takes
  # the old path untouched. Nothing accumulates onto an unnamed run, because there is nothing to
  # tell it apart from the next unnamed run.
  class RunRecorder
    # Two shards racing is the ordinary case; three collisions in a row on the same key would mean
    # the row is being created and rolled back repeatedly, which is not something retrying fixes.
    MAX_ATTEMPTS = 3

    def self.record(repository, attributes) = new(repository, attributes).record

    def initialize(repository, attributes)
      @repository = repository
      @attributes = attributes
      @ci_run_id = attributes[:ci_run_id]
    end

    # @return [TestRun] the row this request landed in, with the accumulated counts already
    #   loaded — the controller renders its totals straight back to the client.
    def record
      return create_run if @ci_run_id.blank?

      attempts = 0

      begin
        attempts += 1
        existing = find_run
        existing ? accumulate(existing) : create_run
      rescue ActiveRecord::RecordNotUnique
        # Lost the race: another shard inserted the row between the lookup and the insert. The
        # partial unique index on `(repository_id, ci_run_id)` is what turned that into an
        # exception rather than a second row, so the retry finds the winner and accumulates onto
        # it. Without the rescue, the shard that lost answers 500 and its slice of the suite is
        # discarded — and four shards POSTing at the end of one CI job is the *expected* traffic
        # here, not a corner case.
        raise if attempts >= MAX_ATTEMPTS

        retry
      end
    end

    private

    def find_run = @repository.test_runs.find_by(ci_run_id: @ci_run_id)

    def create_run
      return @repository.test_runs.create!(@attributes) if @ci_run_id.blank?

      # A SAVEPOINT, so that when this insert loses the race the rollback stops here. Without
      # `requires_new` the insert merely *joins* whatever transaction the caller is already inside,
      # and Postgres aborts that entire transaction on a constraint violation — which would leave
      # the retry below holding a connection that refuses every subsequent statement. Nothing wraps
      # an ingest request in a transaction today, so this costs one round trip and buys the
      # correctness for the day something does.
      TestRun.transaction(requires_new: true) { @repository.test_runs.create!(@attributes) }
    end

    # Adds this shard's slice to the run's running totals.
    #
    # `update_counters` issues a single `SET count = COALESCE(count, 0) + n` — the increment
    # happens in the database, so two shards accumulating at once cannot read the same value and
    # write it back twice. A read-modify-write here would silently lose a shard's counts under
    # exactly the concurrency this class is built for.
    def accumulate(run)
      TestRun.update_counters(run.id,
                              total_specs_count: @attributes[:total_specs_count].to_i,
                              annotated_specs_count: @attributes[:annotated_specs_count].to_i)
      widen_duration(run)

      # `update_counters` writes straight to the database and leaves this instance holding the
      # values it was loaded with, so the caller would render the *previous* shard's totals back
      # to this one. `Api::V1::IngestsController#create` reports these numbers, so the reload is
      # part of the answer, not housekeeping.
      run.reload
    end

    # `duration_seconds` is the one field that is a MAX rather than a sum. Shards run
    # concurrently, so summing four 8-minute shards would report a 32-minute run that took 8 —
    # a number no operator could reconcile with their CI dashboard.
    #
    # `GREATEST` in SQL for the same reason the counts are: the comparison has to happen where the
    # write happens, or two shards finishing together each widen from a stale read.
    def widen_duration(run)
      duration = @attributes[:duration_seconds]
      return if duration.nil?

      TestRun.where(id: run.id)
             .update_all(["duration_seconds = GREATEST(COALESCE(duration_seconds, 0), ?)", duration])
    end
  end
end
