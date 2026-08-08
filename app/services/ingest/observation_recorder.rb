# frozen_string_literal: true

module Ingest
  # Writes one `SpecObservation` per example of one delivery, and is the only thing that does.
  #
  # Split out of {Ingest::RunRecorder} rather than inlined so the re-delivery doctrine stays in one
  # place: the run's counters are *derived* from `test_run_shards` and therefore idempotent by
  # construction, but rows written per POST inherit none of that protection unless they are keyed
  # the same way. So they are — **delete this shard's rows, then insert them** — which is the whole
  # of this class.
  #
  # == The three shapes, and what each one gets
  #
  # * **Named shard** (`shard_id` present) — `RunRecorder#upsert_shard` returns the *same*
  #   `TestRunShard` row on redelivery, so deleting by `test_run_shard_id` removes exactly the
  #   previous delivery and the insert replaces it. Re-running shard 2 of a four-shard run leaves
  #   the suite counted once. Fully idempotent.
  # * **Anonymous slice** (`ci_run_id` present, `shard_id` nil) — a fresh `TestRunShard` row per
  #   POST, because a client that shards without naming its slices sends nothing to tell them
  #   apart. The delete therefore matches nothing. `RunRecorder` documents that the shard
  #   *counters* double in this case and cannot not; the observations do **not** double, because
  #   their key is `(test_run_id, example_id)` and the conflicting rows are skipped rather than
  #   inserted. That asymmetry is worth stating plainly rather than being discovered: this class
  #   does not fix the anonymous-slice hazard, it is merely not exposed to it.
  # * **No `ci_run_id`** — no shard rows exist at all, `test_run_shard_id` is null, and every POST
  #   is its own `TestRun`. There is nothing to collide with.
  #
  # == Two decisions the wire format forces
  #
  # `example_id` arrives **unvalidated** — `Ingest::Payload` checks `file_path`, `line_number`,
  # `status` and `intent`, and nothing else. A payload with a repeated `id` would violate the
  # unique index and take the whole ingest down with a 500, which is a far worse answer than
  # storing one row for a duplicated id. So the write is tolerant: `insert_all` conflicting on
  # `(test_run_id, example_id)` does nothing rather than raising, and the first row wins. A
  # producer that sends no `id` at all is unaffected — the unique index is not partial and
  # Postgres treats NULLs as distinct, so those examples each get their own row. Rejecting the run
  # instead is envelope validation's call to make, not this class's.
  #
  # `insert_all` runs no callbacks and derives nothing, so `created_at` / `updated_at` are written
  # by hand and `repository_id` — denormalised onto the row so repository-scoped reads need no
  # join — is written explicitly rather than inherited from an association.
  #
  # == The trade
  #
  # This runs inside the transaction already holding the run's `FOR UPDATE` lock (see
  # `RunRecorder#record` for why that lock is taken where it is). N shards therefore **serialize**
  # their bulk inserts rather than running them concurrently. That is the price of the paragraph
  # above: a delete-then-insert keyed on the shard is only atomic against a concurrent delivery if
  # something is holding the run still while it happens. Bulk `insert_all` rather than N
  # `create!`s is what keeps the serialized section short — 20,000 examples is the design point,
  # and it is one statement.
  class ObservationRecorder
    def self.record(run, specs, shard: nil) = new(run, specs, shard: shard).record

    def initialize(run, specs, shard: nil)
      @run = run
      @specs = specs || []
      @shard = shard
    end

    # @return [Integer] how many rows this delivery actually inserted — which is not always
    #   `specs.size`, since a conflicting id is skipped rather than stored.
    def record
      @run.spec_observations.where(test_run_shard_id: @shard&.id).delete_all

      rows = build_rows
      return 0 if rows.empty?

      # `insert_all` (as against `insert_all!`) emits `ON CONFLICT … DO NOTHING`, and naming the
      # conflict target says out loud which key is being tolerated rather than leaving "any
      # constraint at all" implied. First row wins, both within one payload and against a delivery
      # this one could not delete.
      SpecObservation.insert_all(rows, unique_by: %i[test_run_id example_id]).count
    end

    private

    def build_rows
      now = Time.current

      @specs.filter_map do |spec|
        attributes(spec, now) if spec.is_a?(Hash)
      end
    end

    def attributes(spec, now)
      {
        test_run_id: @run.id,
        repository_id: @run.repository_id,
        test_run_shard_id: @shard&.id,
        example_id: presence_of(spec["id"]),
        # The *including* file, which is what makes duration-by-file aggregate to the file that
        # ran the test rather than to a `spec/support/` helper. Falls back to the definition site
        # for a producer old enough not to send it — a null would drop the row out of every
        # by-file total, which is worse than attributing it to the only file we were told about.
        spec_file_path: presence_of(spec["spec_file_path"]) || spec["file_path"],
        file_path: spec["file_path"],
        line_number: spec["line_number"],
        name: presence_of(spec["name"]),
        # `duration` and `outcome` are `result&.run_time` / `result&.status&.to_s` on the client.
        # The safe navigation is real — an example that never ran has neither — so a nil here is a
        # faithful record rather than a gap to paper over.
        duration_seconds: spec["duration"],
        outcome: presence_of(spec["outcome"]),
        status: spec["status"],
        created_at: now,
        updated_at: now
      }
    end

    # `presence` on a value that may be any JSON type, coerced to the string the column holds.
    # Blank becomes nil so that `""` and "the client did not send it" are one state, not two.
    def presence_of(value)
      return nil if value.nil?

      value.to_s.presence
    end
  end
end
