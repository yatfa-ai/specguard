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
  # == Two ids, because one is not enough
  #
  # `ci_run_id` is the client's CI provider's id for the build (`GITHUB_RUN_ID`, `CI_PIPELINE_ID`,
  # …) and says *which run* this is. `shard_id` says *which slice of it*.
  #
  # The second is not decoration, and the reason is that provider run ids are documented as stable
  # across a re-run: GitHub's `GITHUB_RUN_ID` is *"A unique number for each workflow run within a
  # repository. This number does not change if you re-run the workflow run."*, Buildkite retries a
  # job inside the same `BUILDKITE_BUILD_ID`, GitLab inside the same `CI_PIPELINE_ID`. An earlier
  # version of this class keyed on the run id alone and simply added each arriving payload to the
  # row's counters, which meant it could add a slice but never *recognise* one. Pressing "re-run
  # failed jobs" — the mainline recovery gesture for a sharded suite, since re-running all 20,000
  # examples to chase one flaky shard is the thing sharding exists to avoid — then added the
  # retried shard on top of the slice it was replacing. Measured on that implementation, re-running
  # one 5,100-example shard of a 20,000-example suite reported a 25,100 denominator, and the
  # headline ratio moved by however annotated that particular shard happened to be. Wrong rather
  # than merely partial, and invisible in the data.
  #
  # So the run's numbers are not accumulated at all. Each POST records its own
  # {TestRunShard}, and the `TestRun`'s counts are **derived** from those rows — SUM for the
  # counts, MAX for the duration — after every ingest. A shard that reports twice overwrites its
  # own row, so re-running one shard, re-running all of them, and re-delivering the same shard
  # repeatedly all converge on the same totals. Keeping the run id stable across attempts is then
  # the *wanted* behaviour rather than a hazard: a retried shard lands back on the run it belongs
  # to instead of forming a new run holding only the shards that happened to be retried.
  #
  # A run with **no** `ci_run_id` — a laptop `bundle exec rspec`, an unrecognised provider — takes
  # the old path untouched: one `create!`, no shard rows, nothing derived. Nothing folds onto an
  # unnamed run, because there is nothing to tell it apart from the next unnamed run.
  #
  # == The other half of a delivery
  #
  # Each POST also lands one row per example in `spec_observations`, written by
  # {Ingest::ObservationRecorder} inside this same transaction. Those rows are replaced rather than
  # appended, for exactly the reason the counters are derived rather than accumulated — the 25,100
  # denominator above is what a per-delivery append looks like, and rows inherit none of the
  # counters' protection unless they are keyed the same way. Replacing them takes two keys rather
  # than one: the delete is per-shard, because a delivery knows only its own slice, while the
  # conflict clause is per-run, because a queue-based splitter moves examples between shards and an
  # example on the far side of the delete is reachable only there. `ObservationRecorder` carries
  # the argument. The run's own `total_specs_count` / `annotated_specs_count` are **not** re-derived
  # from those rows: those stay a function of `test_run_shards`, unchanged.
  #
  # Those rows are also the only thing here that grows without bound, so this class is where the
  # bound is applied: after the transaction below commits — never inside it — the delivery's own
  # branch is pruned back to `SpecObservation::BRANCH_RETENTION_RUNS` runs by
  # {Ingest::ObservationPruner}. Enforcement lives at the write path rather than in a scheduled
  # job, because the write path is where the growth happens and it is the one place guaranteed to
  # run whenever it does.
  class RunRecorder
    # Two shards racing is the ordinary case; three collisions in a row on the same key would mean
    # the row is being created and rolled back repeatedly, which is not something retrying fixes.
    MAX_ATTEMPTS = 3

    def self.record(repository, attributes, shard_id: nil, specs: [])
      new(repository, attributes, shard_id: shard_id, specs: specs).record
    end

    def initialize(repository, attributes, shard_id: nil, specs: [])
      @repository = repository
      @attributes = attributes
      @shard_id = shard_id
      @specs = specs
      @ci_run_id = attributes[:ci_run_id]
    end

    # @return [TestRun] the row this request landed in, with the run's derived totals already
    #   loaded — the controller renders them straight back to the client.
    def record
      return record_unsharded_run if @ci_run_id.blank?

      run = nil

      # Finding-or-creating the run and recording its first slice are one transaction on purpose.
      # A `TestRun` with a `ci_run_id` gets its counts from its shards, so a row that existed
      # without any would read as an empty run — and worse, the *next* shard to arrive would
      # recompute the totals down to its own slice alone, quietly discarding the counts the failed
      # request had already written. The invariant is "a run with a `ci_run_id` always has at least
      # one shard", and this is what holds it.
      TestRun.transaction do
        run = find_or_create_run

        # Take the run's exclusive lock BEFORE inserting the shard row, not after. This ordering
        # is load-bearing and its absence is a deadlock, not a slowdown.
        #
        # `test_run_shards.test_run_id` is a foreign key, so inserting a shard makes Postgres take
        # a `FOR KEY SHARE` lock on the parent `test_runs` row to stop it vanishing mid-insert.
        # That lock is shared, so all N shards acquire it happily — and then all N ask to upgrade
        # it to the `FOR UPDATE` the recompute needs. Every one of them is waiting for the others
        # to let go of a lock none of them will release before it gets the upgrade, which is a
        # deadlock by construction. Measured on 8 concurrent shards before this line moved: 6 of 8
        # died with `PG::TRDeadlockDetected` and their slices were lost, on every run.
        #
        # Locking first means each shard holds the exclusive lock for its whole
        # insert-and-recompute and releases it on commit: no upgrade, so nothing to deadlock over.
        # It also gives the recompute the property it needs — the last transaction to hold this
        # lock can only have got it after every other committed, so its aggregate sees them all.
        #
        # No in-suite example can catch a regression here: a request spec runs inside a single
        # transaction and never contends with itself. `spec/requests/api/v1/ingest_spec.rb` says
        # as much where it fakes the create-race; the real proof is out of band, on real threads
        # and real connections.
        run.lock!

        shard = upsert_shard(run)
        Ingest::ObservationRecorder.record(run, @specs, shard: shard)
        recompute_totals(run)
      end

      prune_observations(run)

      run.reload
    end

    private

    # Enforces the retention rule on the branch this run is on — see {Ingest::ObservationPruner}
    # for the rule and for why it is keyed per branch rather than per repository.
    #
    # **After the transaction above has committed, and outside it.** The lock that transaction
    # holds is measured and load-bearing (see `#record`), and lengthening it is how this ingest
    # path deadlocks; the prune needs none of its protection, because the only rows it touches
    # belong to runs OLDER than the retained window, which no concurrent delivery is writing.
    # Called on both paths — here and in `#record_unsharded_run` — each after its own commit,
    # because a laptop `bundle exec rspec` grows this table exactly as a CI matrix does.
    def prune_observations(run) = Ingest::ObservationPruner.prune(run)

    # A run no CI provider named: one `create!`, no shard rows, nothing derived — the path this
    # class had before sharding existed. The only addition is that its examples are recorded too,
    # in the same transaction, so a run either has both halves or neither. `test_run_shard_id` is
    # null on every one of these rows because there is no shard row to point at, and each POST is
    # its own `TestRun`, so there is nothing for a redelivery to collide with.
    def record_unsharded_run
      run = TestRun.transaction do
        create_run.tap { |unsharded| Ingest::ObservationRecorder.record(unsharded, @specs) }
      end

      prune_observations(run)

      run
    end

    def find_or_create_run
      attempts = 0

      begin
        attempts += 1
        find_run || create_run
      rescue ActiveRecord::RecordNotUnique
        # Lost the race: another shard inserted the row between the lookup and the insert. The
        # partial unique index on `(repository_id, ci_run_id)` is what turned that into an
        # exception rather than a second row, so the retry finds the winner and contributes to
        # it. Without the rescue, the shard that lost answers 500 and its slice of the suite is
        # discarded — and four shards POSTing at the end of one CI job is the *expected* traffic
        # here, not a corner case.
        #
        # Safe to retry from inside the enclosing transaction because the insert that raised was
        # wrapped in its own SAVEPOINT (see `create_run`), so only that statement was rolled back
        # and this connection is still usable.
        raise if attempts >= MAX_ATTEMPTS

        retry
      end
    end

    def find_run = @repository.test_runs.find_by(ci_run_id: @ci_run_id)

    def create_run
      return @repository.test_runs.create!(@attributes) if @ci_run_id.blank?

      # A SAVEPOINT, so that when this insert loses the race the rollback stops here. Without
      # `requires_new` the insert merely *joins* whatever transaction the caller is already inside,
      # and Postgres aborts that entire transaction on a constraint violation — which would leave
      # the retry above holding a connection that refuses every subsequent statement. Nothing wraps
      # an ingest request in a transaction today, so this costs one round trip and buys the
      # correctness for the day something does.
      TestRun.transaction(requires_new: true) { @repository.test_runs.create!(@attributes) }
    end

    # Idempotent when the client named the shard: the same `(test_run_id, shard_id)` is updated in
    # place, so a second delivery replaces the first rather than adding to it.
    #
    # **An anonymous slice — `shard_id` nil — is not idempotent, and cannot be.** A client that
    # shards without exposing an index the gem recognises sends nothing to tell its slices apart,
    # so each POST becomes its own row. That is the right trade in the direction it matters (a
    # slice is counted rather than dropped, and criterion 1's four-shard run still totals
    # correctly), but a redelivered anonymous slice *is* counted twice, and no amount of care here
    # can detect it. The fix is on the client: name the shards. The client README's sharding
    # section says so in those terms, and this is the other end of that sentence.
    #
    # @return [TestRunShard] the row this delivery landed in — not the return of `create!` or
    #   `update!`, which the caller used to discard. `Ingest::ObservationRecorder` keys its
    #   delete-then-insert on this row's **primary key** rather than on the client's `shard_id`
    #   string, which is what makes all three shapes above fall out uniformly: a named shard
    #   resolves to the same row twice and replaces its own observations, an anonymous slice
    #   resolves to a new row and inherits exactly the non-idempotency described above.
    def upsert_shard(run)
      contribution = {
        total_specs_count: @attributes[:total_specs_count].to_i,
        annotated_specs_count: @attributes[:annotated_specs_count].to_i,
        duration_seconds: @attributes[:duration_seconds]
      }

      return run.test_run_shards.create!(contribution) if @shard_id.blank?

      shard = run.test_run_shards.find_or_initialize_by(shard_id: @shard_id)
      shard.update!(contribution)
      shard
    rescue ActiveRecord::RecordNotUnique
      # Two deliveries of the *same* shard racing each other — a retried job overlapping the
      # original, a client retrying a timed-out POST. Both are writing the same slice, so the
      # loser simply re-reads the winner's row and overwrites it; last writer wins is the intended
      # semantic for a shard reporting twice, whether the two reports are a minute or a
      # millisecond apart.
      run.test_run_shards.find_by!(shard_id: @shard_id).tap { |winner| winner.update!(contribution) }
    end

    # Re-derives the run's headline numbers from its slices.
    #
    # Derived rather than incremented, which is what makes the whole thing idempotent: there is no
    # "have I already counted this?" question to get wrong, because nothing is ever counted — the
    # totals are a function of the shard rows, evaluated fresh.
    #
    # `duration_seconds` is the one field that is a MAX rather than a SUM. Shards run
    # concurrently, so summing four 8-minute shards would report a 32-minute run that took 8 — a
    # number no operator could reconcile with their CI dashboard. Being derived, it also *narrows*
    # when the slowest shard is re-run and comes back faster, which an ever-widening `GREATEST`
    # could not do.
    #
    # The caller holds this run's `FOR UPDATE` lock — see `#record` for why that is taken before
    # the shard insert rather than here. Because the lock is already held, the aggregate below is
    # a fresh statement under READ COMMITTED and therefore sees every shard committed by the
    # transactions that released the lock ahead of it, plus this transaction's own.
    def recompute_totals(run)
      totals = run.test_run_shards.pick(
        Arel.sql("COALESCE(SUM(total_specs_count), 0)"),
        Arel.sql("COALESCE(SUM(annotated_specs_count), 0)"),
        Arel.sql("MAX(duration_seconds)")
      )

      run.update_columns(
        total_specs_count: totals[0],
        annotated_specs_count: totals[1],
        duration_seconds: totals[2],
        updated_at: Time.current
      )
    end
  end
end
