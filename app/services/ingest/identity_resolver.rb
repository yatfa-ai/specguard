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
  # == What is deliberately not here
  #
  # Batching the embed calls, caching them, skipping a re-embed when the text is byte-identical to
  # last run's, a `retry_on` / `discard_on` policy, and making a failed embedding identifiable and
  # retryable rather than merely absent — all SPGD-72's, all named as out of scope on SPGD-362. What
  # this class does owe that work is a shape it can build on: the input is columns rather than a job
  # argument, so a retry re-reads it; and an example whose embedding failed stays visible as an
  # unresolved observation rather than becoming a NULL-embedding identity that `nearest_neighbors`
  # would filter out of every future search.
  class IdentityResolver
    # Rows per database round trip on the work list. A repository-scoped ANN lookup and an upsert
    # per row means the loop is round-trip bound whatever this is; the batch only bounds how many
    # observations are held in memory at once, and 20,000 of them is the design point.
    BATCH_SIZE = 500

    def self.resolve(run) = new(run).resolve

    def initialize(run)
      @run = run
      @repository = run.repository
    end

    # @return [Integer] how many observations now carry an identity that did not before. Not
    #   `specs.size`: an example with no text to embed, and one whose embedding failed, are both
    #   left unresolved on purpose.
    def resolve
      resolved = 0

      @run.spec_observations.unresolved.find_each(batch_size: BATCH_SIZE) do |observation|
        identity = identity_for(observation)
        next if identity.nil?

        # `update_column` rather than `update!`: there is nothing to validate on a foreign key the
        # database already enforces, and this runs once per example.
        observation.update_column(:spec_identity_id, identity)
        resolved += 1
      end

      resolved
    end

    private

    # @return [Integer, nil] the id of the identity this observation belongs to, or nil when it has
    #   none to belong to.
    def identity_for(observation)
      signal = observation.signal
      # `:none` — no intent and no name. `Ingest::Payload#validate_name` refuses that shape today,
      # so this is for rows written before it existed. There is no text to embed and therefore no
      # identity to have; the row stays unresolved, which is the honest answer rather than an
      # identity standing for nothing.
      return nil unless signal.present?

      embedding = embed(signal.text)
      return nil if embedding.nil?

      match = nearest(embedding)
      return resight(match, observation) if match

      claim_identity(signal, embedding, observation)
    end

    # The nearest existing identity in THIS repository, if one is close enough to be the same test.
    #
    # Repository-scoped because identity is per repository — two codebases sharing a test name share
    # nothing else, and the tenant boundary is not a thing similarity gets to cross. `threshold:` is
    # `neighbor`'s own, a cosine *distance*, so the comparison lands in SQL rather than being
    # re-derived from `neighbor_distance` here; `first` on an ordered relation is `LIMIT 1`.
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
      identity.update_columns(
        file_path: observation.file_path, line_number: observation.line_number,
        last_seen_test_run_id: @run.id, updated_at: Time.current
      )
      identity.id
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
          embedding: embedding,
          file_path: observation.file_path,
          line_number: observation.line_number,
          last_seen_test_run_id: @run.id,
          created_at: now,
          updated_at: now
        }],
        unique_by: %i[repository_id text_digest], update_only: SpecIdentity::RESIGHTABLE,
        record_timestamps: false, returning: %w[id]
      ).rows.dig(0, 0)
    end

    # @return [Array<Float>, nil] nil when the provider failed, which leaves the observation
    #   unresolved and the next run free to try again.
    #
    # Rescued rather than allowed to propagate so that one unembeddable example does not abandon the
    # other 19,999 — and rescued *here*, at the single call, so the rescue cannot accidentally swallow
    # a failure from the database work around it. `EmbeddingGenerator` promises this is the only class
    # its callers see, whatever the provider did.
    #
    # Logged and nothing more. Making this state queryable and retryable is SPGD-72's; what this
    # slice owes it is that the state exists somewhere findable, and it does: the observation keeps a
    # NULL `spec_identity_id`.
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
