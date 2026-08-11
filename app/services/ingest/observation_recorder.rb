# frozen_string_literal: true

module Ingest
  # Writes one `SpecObservation` per example of one delivery, and is the only thing that does.
  #
  # Split out of {Ingest::RunRecorder} rather than inlined so the re-delivery doctrine stays in one
  # place: the run's counters are *derived* from `test_run_shards` and therefore idempotent by
  # construction, but rows written per POST inherit none of that protection unless they are keyed
  # the same way. So the write is **delete this shard's rows, then upsert the delivery** — and the
  # two halves of that sentence are keyed differently on purpose, for a reason that took a
  # measurement to find.
  #
  # == Why the delete is per-shard and the conflict key is per-run
  #
  # The delete can only be per-shard. A delivery knows its own slice and nothing about the others,
  # so deleting the run's rows would make shard 2 erase shard 1.
  #
  # The conflict key cannot be per-shard, because **examples move between shards**. A queue-based
  # splitter — Knapsack Pro queue mode, `parallel_tests --group-by runtime` — rebalances slices
  # between runs, which is the entire reason to use one. `example_id` is
  # `"./spec/foo_spec.rb[1:1]"`, so it travels with the file. Re-running shard A after the splitter
  # has handed it an example shard B used to own leaves a row the delete cannot reach, and the
  # fresh measurement arrives on top of it.
  #
  # So a collision **updates** rather than being skipped: last writer wins, which is the same
  # semantic `RunRecorder#upsert_shard` already chose for a shard reporting twice. Measured on the
  # `DO NOTHING` version of this class — shard A holding an example at 1.0s, shard B holding
  # another at 9.0s, then A re-run with B's example coming back at 0.5s — the platform kept the
  # 9.0s, discarded the 0.5s, and went on attributing the example to the shard that no longer ran
  # it, with nothing in the data to say so. `DO UPDATE` also re-points `test_run_shard_id` at the
  # slice that actually ran the example, so ownership and measurement move together.
  #
  # One consequence to state rather than let someone find: an example that leaves shard A for
  # shard B is absent from the run between A's redelivery and B's. It returns when B delivers. The
  # counters have exactly this property for exactly this reason — a sharded run is whole only once
  # every shard has reported — so it converges rather than drifting.
  #
  # == A repeated id inside one payload is a different event, handled a different way
  #
  # `example_id` arrives **unvalidated**: `Ingest::Payload` checks `file_path`, `line_number`,
  # `status` and `intent`, and nothing else. A payload repeating an id would make Postgres raise
  # `ON CONFLICT DO UPDATE command cannot affect row a second time` and take the whole ingest down
  # with a 500, so the repeat is collapsed **in Ruby**, first occurrence winning, before the
  # statement is built. Deliberately not left to `DO UPDATE`: two rows in one payload are a
  # producer bug and the second is no more trustworthy than the first, whereas two deliveries are a
  # remeasurement and the newer one is precisely what is wanted. Rejecting the payload outright is
  # envelope validation's call, not this class's.
  #
  # == The three shapes, and the one that has no answer
  #
  # * **Named shard** (`shard_id` present) — `RunRecorder#upsert_shard` returns the *same*
  #   `TestRunShard` row on redelivery, so deleting by `test_run_shard_id` removes exactly the
  #   previous delivery and the upsert replaces it. Re-running shard 2 of a four-shard run leaves
  #   the suite counted once. Fully idempotent.
  # * **No `ci_run_id`** — no shard rows exist at all, `test_run_shard_id` is null, and every POST
  #   is its own `TestRun`. There is nothing to collide with.
  # * **Anonymous slice** (`ci_run_id` present, `shard_id` nil) — a fresh `TestRunShard` row per
  #   POST, because a client that shards without naming its slices sends nothing to tell them
  #   apart. The delete therefore matches nothing, and the conflict key is the only thing standing
  #   between a redelivery and a doubled run.
  #
  #   It stands there **only for a producer that sends `id`s**, and that precondition is the whole
  #   reason this paragraph exists. Postgres treats NULLs as distinct in a unique index — which is
  #   what lets an id-less producer keep one row per example instead of collapsing to one row per
  #   run — and it is the very same property that leaves an id-less redelivery nothing to conflict
  #   *with*. Measured: an anonymous slice carrying one id-less example, delivered twice, leaves
  #   two rows. No key fixes that. The only candidate is `(file_path, line_number)`, which is the
  #   coordinate a table-driven loop puts N examples on and the exact collapse this table exists to
  #   avoid — so paying for redelivery safety there would cost the grain, permanently, for every
  #   producer. It is therefore a **known gap**, asserted as one in
  #   `spec/requests/api/v1/ingest_spec.rb` rather than left to be discovered, and its fix is the
  #   same client-side fix as for the doubled counters `RunRecorder#upsert_shard` documents: name
  #   the shards, or send ids.
  #
  # == Mechanics
  #
  # `upsert_all` runs no callbacks and derives nothing, so `created_at` / `updated_at` are written
  # by hand and `repository_id` — denormalised onto the row so repository-scoped reads need no
  # join — is written explicitly rather than inherited from an association. `created_at` is kept
  # out of the update list because the columns a collision may move are the *measurement*, not the
  # row's own history — so a row remeasured through the `DO UPDATE` branch keeps when it first
  # appeared and moves only its `updated_at`. A row its own shard re-delivers is deleted and
  # written afresh instead, and starts a new history, which is the honest record of what happened
  # to it.
  #
  # == The trade
  #
  # This runs inside the transaction already holding the run's `FOR UPDATE` lock (see
  # `RunRecorder#record` for why that lock is taken where it is). N shards therefore **serialize**
  # their bulk inserts rather than running them concurrently. That is the price of the paragraph
  # above: a delete-then-upsert keyed on the shard is only atomic against a concurrent delivery if
  # something is holding the run still while it happens. One bulk `upsert_all` rather than N
  # `create!`s is what keeps the serialized section short — 20,000 examples is the design point,
  # and it is one statement.
  class ObservationRecorder
    # Everything a redelivery is allowed to move. `created_at` is absent so a remeasured row keeps
    # when it first appeared, and the conflict key itself is absent because Postgres will not let
    # `DO UPDATE` touch the columns it matched on.
    #
    # `spec_identity_id` is absent too, and for a third reason: a redelivery re-measures a test, it
    # does not re-identify one, so a row already resolved keeps its link while its measurement
    # moves. A row its own shard re-delivers is deleted and recreated rather than updated, so that
    # one comes back unresolved and the next {Ingest::IdentityResolutionJob} claims it again — both
    # paths converge on the same identity, because the identity is a function of the text and the
    # text is what was re-sent.
    #
    # **`embed_failed_at` and `embed_failure_count` are absent by the same reasoning, stated rather
    # than omitted.** They are identity-resolution facts, not measurements: a redelivery says what
    # the test COST this time, and it says nothing whatever about whether the embedding provider was
    # reachable when the resolver last asked. So a redelivered row keeps its place in
    # {Ingest::IdentityResolver}'s retry backlog while its duration and outcome move — which is what
    # the retry needs, since the rescue is about the row's *resolution* and the redelivery did not
    # perform one. `#attributes` correspondingly does not write them, so they are not in the
    # statement at all: an insert takes the column defaults and a `DO UPDATE` cannot reach them.
    #
    # The delete-then-recreate path clears both, and that is correct rather than a leak. That path
    # already "starts a new history" for the row, per the class comment above; the recreated row is
    # genuinely unresolved-and-unattempted, the resolver will attempt it in the ordinary way, and if
    # the provider is still down it earns a fresh stamp on its own merits. What must not happen is a
    # row silently keeping a stamp for an embedding attempt that no longer refers to it.
    REMEASURABLE = %i[
      test_run_shard_id spec_file_path file_path line_number name intent_entity intent_action
      intent_behavior duration_seconds outcome status updated_at
    ].freeze

    def self.record(run, specs, shard: nil) = new(run, specs, shard: shard).record

    def initialize(run, specs, shard: nil)
      @run = run
      @specs = specs || []
      @shard = shard
    end

    # @return [Integer] how many rows this delivery wrote, inserted and remeasured together. Not
    #   always `specs.size`: a payload that repeats an example id contributes one row for it.
    def record
      @run.spec_observations.where(test_run_shard_id: @shard&.id).delete_all

      rows = build_rows
      return 0 if rows.empty?

      # Naming the conflict target says out loud which key is being reconciled rather than leaving
      # "any constraint at all" implied. `record_timestamps: false` because the rows already carry
      # theirs and the pair above decides which of them a collision may move.
      SpecObservation.upsert_all(
        rows, unique_by: %i[test_run_id example_id], update_only: REMEASURABLE, record_timestamps: false
      ).count
    end

    private

    # One row per example, with a repeated `example_id` collapsed to its first occurrence — see the
    # class comment for why that is a Ruby-side concern rather than the conflict clause's. Rows
    # carrying no id are all kept: they cannot collide with each other, in this statement or any
    # other, which is the same fact from both directions.
    def build_rows
      now = Time.current
      claimed = Set.new

      @specs.filter_map do |spec|
        next unless spec.is_a?(Hash)

        row = attributes(spec, now)
        next if row[:example_id] && !claimed.add?(row[:example_id])

        row
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
        # The declared intent, kept at last. `Ingest::Payload` validates this triple against the
        # OpenTestIntent schema and counts it into `annotated_specs_count`, and until now nothing
        # wrote it anywhere — so every cross-run read was forced onto `name` alone and annotating a
        # test changed nothing about its identity, the exact outcome `Ingest::SpecSignal` exists to
        # prevent. Read here rather than passed to the resolver through a job argument, because a
        # 20,000-example run would otherwise put 20,000 spec hashes into `solid_queue_jobs`.
        #
        # Read straight off the wire, not through `SpecSignal`: this records the three fields the
        # client sent, and deciding which of them *represents* the test is a question with one
        # owner, asked later against these columns by `SpecObservation#signal`.
        **intent_attributes(spec["intent"]),
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

    # The three intent fields, or three nils. Always all three keys, never a subset: `upsert_all`
    # builds one statement from the first row's keys, so a row omitting them would take the whole
    # delivery's columns with it and silently drop the intent of every annotated example behind an
    # unannotated first one.
    #
    # `layer` and `preconditions` are deliberately not read — see the migration.
    def intent_attributes(intent)
      intent = {} unless intent.is_a?(Hash)

      {
        intent_entity: presence_of(intent["entity"]),
        intent_action: presence_of(intent["action"]),
        intent_behavior: presence_of(intent["behavior"])
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
