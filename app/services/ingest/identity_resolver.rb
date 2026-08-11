# frozen_string_literal: true

module Ingest
  # Maps every example one run ingested onto the durable {SpecIdentity} it belongs to, and is the
  # only thing that writes that table.
  #
  # For each unresolved observation: take the text that represents it ({SpecObservation#signal},
  # which defers to {Ingest::SpecSignal}), embed it, ask this repository's identities for the
  # nearest neighbour within {SpecIdentity::MATCH_DISTANCE}, and either re-sight the row that came
  # back or insert a new one. The observation is then pointed at whichever it was.
  #
  # == Why this runs in a job and not in the ingest transaction
  #
  # {Ingest::ObservationRecorder} writes inside the transaction holding the run's `FOR UPDATE` lock,
  # and its class comment explains at length why that lock is taken where it is: a delete-then-upsert
  # keyed on the shard is only atomic against a concurrent delivery if something holds the run still
  # while it happens. N shards therefore serialize there, which is affordable because the whole
  # section is one bulk statement.
  #
  # This is not one statement. At the 20,000-example design point it is 20,000 embeddings and 20,000
  # index lookups, and putting that inside the serialized section would make every other shard of
  # the run wait behind it. That is the reason the ingest endpoint answers `202` before any per-spec
  # work and the reason the `enqueue_embeddings` seam exists at all. So resolution runs afterwards,
  # out of band, against rows that are already committed.
  #
  # == Idempotency, and the two ways it is reached twice
  #
  # Every shard of a run enqueues a job for the *run*, so an N-shard delivery schedules N jobs over
  # the same rows, and a redelivered shard schedules another. Both are ordinary, and neither is
  # special-cased:
  #
  # * The work list is `SpecObservation.unresolved`, so a row already claimed is simply not in it.
  # * Two jobs that read the list at the same moment and both miss on the same text converge on one
  #   row, because the insert is an upsert onto `(repository_id, text_digest)` — see
  #   {#claim_identity} and the migration's "The conflict key" section.
  #
  # == The work list is TWO lists, and the second is what makes a failure recoverable
  #
  # This run's unresolved observations, and — before them — the rows of the repository's EARLIER runs
  # whose embedding failed and which nothing else will ever revisit. Until that second list existed
  # there was exactly one `perform_later` in the whole application and its argument was the run just
  # created, so run-1's failed rows were never read again by anything: run-2's job walks run-2's
  # rows. The identity was not lost — run-2 re-creates it from the same text — but run-1's duration
  # and outcome stayed orphaned from that test's history permanently, which is the half of "nothing
  # is permanently lost" that was not true.
  #
  # The trigger is deliberately the next INGEST rather than a scheduled sweep. `config/recurring.yml`
  # has one production entry and it is Solid Queue housekeeping; adding a cron is a deployment
  # concern and a second thing that can be off. An ingest is the moment the answer can have changed
  # and the moment somebody is waiting for it, and it is already enqueuing this job.
  #
  # == What is deliberately not here
  #
  # Batching the embed calls, caching them, and skipping a re-embed when the text is byte-identical
  # to last run's — the *Cost* axis, still SPGD-72's, deliberately not bundled into a correctness
  # fix. Also the ANN recall measurement {#nearest} hands over by name.
  #
  # **Not** a `retry_on` / `discard_on` policy on {Ingest::IdentityResolutionJob}, and that omission
  # is now a finding rather than a deferral: `retry_on EmbeddingGenerator::Error` cannot fire.
  # {#embed} rescues that class at the single call site and returns nil, so the error never reaches
  # ActiveJob and the job always completes *successfully* having resolved nothing. The rescue is
  # deliberate — one unembeddable example must not abandon the other 19,999 — so the retry has to
  # live in the work list, which is where it now lives.
  class IdentityResolver
    # Rows per database round trip on the work list. A repository-scoped ANN lookup and an upsert
    # per row means the loop is round-trip bound whatever this is; the batch only bounds how many
    # observations are held in memory at once, and 20,000 of them is the design point.
    BATCH_SIZE = 500

    # **How much of an earlier run's failure ONE ingest is made to pay for.** The cost bound on the
    # cross-run sweep, and its own constant rather than a reuse of `BATCH_SIZE` by the rule this
    # codebase's `_LIMIT`s obey: that one bounds how many rows are held in MEMORY at once and would
    # be just as correct at 50 or 5,000, this bounds how much EXTRA WORK a delivery inherits from
    # deliveries before it. They move for different reasons and one number standing for both would
    # make that a single edit nobody meant to make.
    #
    # A bound is needed because the failure mode is the design point: a provider outage across a
    # 20,000-example run leaves 20,000 failed rows, and an uncapped sweep would make the very next
    # ingest do 40,000 embeddings — its own suite plus the whole backlog — on the one path that is
    # already the largest thing this application does. Capped, an ingest is at worst its own suite
    # plus 500, and a backlog larger than the cap drains across the ingests that follow instead of
    # landing on one of them.
    #
    # It is a cap on ROWS and never a fraction of the run, so a small delivery cannot be made to
    # carry a large one's backlog in proportion to itself. Sized at the same order as one batch: the
    # sweep loads its rows in a single query rather than in batches, so this is also what keeps that
    # load the size of one `BATCH_SIZE` page — the coincidence of value is not a coincidence of
    # meaning, which is precisely why they are two constants.
    RETRY_SWEEP_LIMIT = 500

    def self.resolve(run) = new(run).resolve

    def initialize(run)
      @run = run
      @repository = run.repository
    end

    # @return [Integer] how many observations now carry an identity that did not before — **across
    #   both lists**, so a rescued row of an earlier run is counted here too. Not `specs.size`, and
    #   deliberately not "observations OF THIS RUN": the number says what this invocation resolved,
    #   which is the only thing it has ever been read as and the only thing the caller could act on.
    #   A run whose own rows all resolved and which rescued four earlier ones returns the four; the
    #   alternative — counting only `@run`'s rows — would report a sweep that did real work as a
    #   no-op. `spec/services/ingest/identity_resolver_spec.rb`'s "running twice over the same run"
    #   example is unaffected either way: a repository with no failed embeds has an empty backlog.
    def resolve
      resolved = 0

      # **The backlog first, and the order is load-bearing.** A re-sighting moves the identity's
      # "last known path", so whichever observation is resolved LAST has the final word on where the
      # test was last seen. The backlog is by definition older than this run, so resolving it second
      # would let run-1's path overwrite run-2's on the identity run-2 had just correctly placed —
      # a last-known-path that goes backwards in time. Oldest first, newest last, so the newest run
      # wins by being last, which is the same last-writer-wins semantic {#resight} already has
      # within a single run.
      retry_backlog.each { |observation| resolved += claim(observation) }

      @run.spec_observations.unresolved.find_each(batch_size: BATCH_SIZE) do |observation|
        resolved += claim(observation)
      end

      resolved
    end

    private

    # The rows EARLIER runs of this repository failed to embed, and which this ingest is entitled to
    # re-attempt. Empty on a repository whose provider has never failed, which is the normal case
    # and costs one probe of an index that is empty there — see the migration for why the index is
    # partial.
    #
    # Scoped to the repository because identity is per repository and so is the provider outage that
    # produced these rows; `@repository` is already in hand from {#initialize}. `@run` is EXCLUDED
    # rather than left in: this run's own unresolved rows are the second list, and a row that
    # appeared on both would be embedded twice in one pass — once for nothing.
    #
    # Ordered least-tried first, which is what stops a backlog bigger than `RETRY_SWEEP_LIMIT` from
    # starving its own tail. A pure `embed_failed_at` ordering re-attempts the same 500 rows on every
    # ingest until the window closes on all 20,000 at once — they failed in the same outage, so they
    # expire together and 19,500 of them never get a single retry. Ordering on `embed_failure_count`
    # makes a retried row sink below the rows that have not been tried yet, so the sweep round-robins
    # the whole backlog instead of a window into it. `embed_failed_at` then `id` break the ties, so
    # the order is total and stable rather than whatever the planner returned first.
    #
    # `.each` and not `find_each`: the relation is already capped at `RETRY_SWEEP_LIMIT`, which is
    # one `BATCH_SIZE` page, and `find_each` ignores exactly the `order` and `limit` this read is.
    def retry_backlog
      @repository.spec_observations
                 .embed_retryable
                 .where.not(test_run_id: @run.id)
                 .order(:embed_failure_count, :embed_failed_at, :id)
                 .limit(RETRY_SWEEP_LIMIT)
    end

    # @return [Integer] 1 when this observation now carries an identity it did not carry before.
    #
    # `update_column` rather than `update!`: there is nothing to validate on a foreign key the
    # database already enforces, and this runs once per example.
    #
    # Counted only when the UPDATE actually matched a row. It returns `affected_rows == 1`, and the
    # row can be gone by the time we get here — a concurrent shard redelivery deletes and re-upserts
    # this run's observations, so one read out of the work list can be stale. Nothing is lost when
    # that happens (the redelivered row is unresolved, so the next job picks it up), but the return
    # value says "observations that NOW carry an identity", and in that window this one does not.
    def claim(observation)
      identity = identity_for(observation)
      return 0 if identity.nil?

      observation.update_column(:spec_identity_id, identity) ? 1 : 0
    end

    # @return [Integer, nil] the id of the identity this observation belongs to, or nil when it has
    #   none to belong to.
    def identity_for(observation)
      signal = observation.signal
      # `:none` — no intent and no name. `Ingest::Payload#validate_name` refuses that shape today,
      # so this is for rows written before it existed. There is no text to embed and therefore no
      # identity to have; the row stays unresolved, which is the honest answer rather than an
      # identity standing for nothing.
      #
      # Returns BEFORE the embed, so it leaves no failure stamp — which is exactly what keeps this
      # population separable from the one below it. A row with nothing to embed is permanently
      # unresolved and must never enter the retry backlog; a row whose embed failed is temporarily
      # unresolved and must.
      return nil unless signal.present?

      embedding = embed(signal.text)
      return record_embed_failure(observation) if embedding.nil?

      match = nearest(embedding)
      return resight(match, observation) if match

      claim_identity(signal, embedding, observation)
    end

    # Writes the one fact that makes this row's absence of an identity mean something: the provider
    # was asked and could not answer.
    #
    # `embed_failed_at` is `COALESCE`d so it holds the FIRST failure and no later one moves it. That
    # is what makes `SpecObservation::EMBED_RETRY_WINDOW` a window that closes rather than one every
    # retry pushes forward — a stamp refreshed on each attempt would keep a hopeless row retryable
    # for exactly as long as anything kept retrying it, which is forever.
    #
    # One UPDATE with the increment computed in SQL rather than read into Ruby and written back,
    # because N shards of a run schedule N jobs over the same rows: two of them reading `0` and both
    # writing `1` would lose an attempt, and the count is what orders the sweep.
    #
    # `updated_at` is deliberately not moved, following {#claim} one method up — resolution facts are
    # written with `update_column`/`update_all` precisely so they do not disturb the row's
    # measurement history, and `Ingest::ObservationRecorder::REMEASURABLE` keeps the two halves apart
    # from the other direction.
    #
    # @return [nil] always — the caller is `identity_for`, and there is still no identity.
    def record_embed_failure(observation)
      SpecObservation.where(id: observation.id).update_all(
        ["embed_failed_at = COALESCE(embed_failed_at, ?), embed_failure_count = embed_failure_count + 1",
         Time.current]
      )

      nil
    end

    # The nearest existing identity in THIS repository, if one is close enough to be the same test.
    #
    # Repository-scoped because identity is per repository — two codebases sharing a test name share
    # nothing else, and the tenant boundary is not a thing similarity gets to cross. `threshold:` is
    # `neighbor`'s own, a cosine *distance*, so the comparison lands in SQL rather than being
    # re-derived from `neighbor_distance` here; `first` on an ordered relation is `LIMIT 1`.
    #
    # == The scope filter is applied AFTER the index scan, and under-recall here costs an identity
    #
    # An HNSW scan produces `hnsw.ef_search` candidates (default 40) from the whole table and only
    # then applies `repository_id`. Today `spec_identities` is small enough that the planner scans
    # it outright and the question does not arise. Once it is large enough across all tenants that
    # the index wins — the 20,000-per-repository design point multiplied by every repository — a
    # small tenant's true nearest neighbour can fall outside those 40 global candidates, and this
    # method returns nothing. A miss here is not a worse ranking, it is a second identity for a test
    # that already had one, and a history split in two. That is what makes it worth stating:
    # `spec_intents` carries the same shape and is only ever ranking.
    #
    # What it cannot cost is the identical-text case — a moved test, or the same test ingested by
    # two shards — because `(repository_id, text_digest)` catches that in {#claim_identity} whatever
    # this returns. The exposure is exactly the near-identical band, the case the spec's "differs
    # only in punctuation and whitespace" example isolates: the bytes differ, so only similarity can
    # find the row.
    #
    # **Deliberately not mitigated here.** pgvector 0.8.0 is installed and `hnsw.iterative_scan`
    # addresses this directly, so the remedy is a one-line `SET` rather than an upgrade. It is left
    # off because of what it costs on the axis this slice is explicitly not allowed to touch:
    # iterative scan keeps descending until enough rows pass the filter or it hits
    # `hnsw.max_scan_tuples`, which makes every *miss* dramatically more expensive — and a
    # repository's first run is 20,000 consecutive misses. Choosing between that, a partitioned or
    # per-tenant index, and a raised `ef_search` is a measurement against the 20k design point, and
    # that is **SPGD-72's**, alongside the batching, caching and re-embed skipping it already owns.
    # Handed to it by name rather than guessed at here.
    def nearest(embedding)
      @repository.spec_identities
                 .nearest_neighbors(:embedding, embedding, distance: "cosine",
                                    threshold: SpecIdentity::MATCH_DISTANCE)
                 .first
    end

    # An existing test, seen again. Moves only where it was last seen — see
    # {SpecIdentity::RESIGHTABLE} for why the text and the vector are not in that set.
    #
    # `update_columns` so this is one UPDATE with no callbacks and no validation pass over a 1536
    # element vector that has not changed.
    def resight(identity, observation)
      identity.update_columns(sighting(observation, Time.current))
      identity.id
    end

    # What "seen again" moves, and the only definition of it. Sliced through
    # {SpecIdentity::RESIGHTABLE} so this method and the `update_only:` clause in {#claim_identity}
    # are the *same* list rather than two copies of it: the match path and the conflict path both
    # end in a re-sighting, and one of them quietly moving a column the other does not is exactly
    # the drift a shared constant is for.
    #
    # `last_seen_test_run_id` comes off the OBSERVATION and never off `@run`, and the two are only
    # equal on the run-scoped half of the work list. A row rescued from the backlog was seen by an
    # EARLIER run, and stamping this ingest's id on it would have the identity claim it was last
    # seen in a run that never contained it. They were the same value until the sweep existed; this
    # is the seam where they stop being.
    def sighting(observation, now)
      { file_path: observation.file_path, line_number: observation.line_number,
        last_seen_test_run_id: observation.test_run_id, updated_at: now }.slice(*SpecIdentity::RESIGHTABLE)
    end

    # A test nothing matched: insert it — or lose the race to insert it and take the winner.
    #
    # `upsert_all` rather than `create!` because the miss is exactly where two ingests collide. Every
    # shard of a repository's first run resolves for the first time, so two of them reaching the same
    # text and both finding nothing is the ordinary case and not a corner. `ON CONFLICT … DO UPDATE
    # … RETURNING id` makes both of them come away holding the same row: the winner inserts, the
    # loser's values land on the winner as an ordinary re-sighting, and neither raises. A
    # `create!`-and-rescue would reach the same place in two statements and a savepoint; this is one
    # statement and needs neither.
    #
    # It is also what makes the *identical-text* case safe twice over. A test that merely moved
    # embeds to the same vector and is found by {#nearest}; if that lookup ever missed it — an
    # approximate index under-recalling, a threshold raised too far — this key would still land the
    # ingest on the row it belongs to rather than growing the table. The two mechanisms overlap on
    # purpose, and only similarity covers the case where the text is *not* byte-identical.
    #
    # `record_timestamps: false` because the row carries its own — {SpecIdentity::RESIGHTABLE} keeps
    # `created_at` out of the update list, so a row that already existed keeps when the test first
    # appeared and moves only its `updated_at`.
    def claim_identity(signal, embedding, observation)
      now = Time.current

      SpecIdentity.upsert_all(
        [{
          repository_id: @repository.id,
          text: signal.text,
          text_digest: SpecIdentity.digest_for(signal.text),
          signal_source: signal.source.to_s,
          embedding: embedding
        }.merge(sighting(observation, now), created_at: now)],
        unique_by: %i[repository_id text_digest], update_only: SpecIdentity::RESIGHTABLE,
        record_timestamps: false, returning: %w[id]
      ).rows.dig(0, 0)
    end

    # @return [Array<Float>, nil] nil when the provider failed, which leaves the observation
    #   unresolved and stamped — see {#record_embed_failure}, which is what the nil now costs.
    #
    # Rescued rather than allowed to propagate so that one unembeddable example does not abandon the
    # other 19,999 — and rescued *here*, at the single call, so the rescue cannot accidentally swallow
    # a failure from the database work around it. `EmbeddingGenerator` promises this is the only class
    # its callers see, whatever the provider did.
    #
    # **This rescue is why a job-level retry policy would reach nothing.** The error is consumed
    # here, so `retry_on EmbeddingGenerator::Error` on {Ingest::IdentityResolutionJob} could never
    # fire and the job reports success having resolved zero rows. Stated at the call that does it,
    # rather than left for a future cycle to derive from an absence.
    #
    # Logged as well as stamped: the log line is what an operator watching a deploy sees, the stamp
    # is what survives to be queried and retried afterwards, and neither is the other.
    def embed(text)
      EmbeddingGenerator.call(text)
    rescue EmbeddingGenerator::Error => e
      Rails.logger.warn(
        "[IdentityResolver] run=#{@run.id} could not embed a spec signal: #{e.message}"
      )
      nil
    end
  end
end
