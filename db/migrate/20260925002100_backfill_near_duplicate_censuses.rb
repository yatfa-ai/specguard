# frozen_string_literal: true

# THE ONE-TIME BACKFILL: every repository that has ingested gets its census computed, by
# enqueuing {Ingest::NearDuplicateCensusJob} for it.
#
# ## Why this migration exists
#
# The census used to be computed live on every `?near_duplicates=` ask, so every repository with
# ingested data had an answer — computed on demand, at the asker's cost. From this deploy the
# answer is served stored, and a repository whose census has never been computed is served `null`.
# Without this migration, every existing repository would read `null` from the deploy instant
# until its next ingest arrived — hours or days of a served regression for data that already
# exists. The backfill closes that window at the deploy: each repository's job computes the census
# over the data as it stands and writes the stored artifact, and the request path picks it up the
# moment it lands.
#
# ## Only repositories that have ingested, and why
#
# A repository with no run has no census to backfill: its honest answer is "never ingested", which
# under the stored contract is served as `null` until its first ingest — the same `null` it served
# before the ask existed, and the state the first ingest's own recompute replaces. Enqueuing work
# for those rows would compute a census of nothing and stamp it, buying no repository an answer
# it could not already read.
#
# ## Why enqueuing and not computing inline
#
# The census is minutes of work on a large suite — that cost is the reason this ticket exists.
# Computing inline in a migration would hold the deploy's database session for the sum of every
# repository's census; enqueueing hands the same work to the worker fleet the ingest path already
# uses, under the job's per-repository concurrency limit, where a slow repository delays nothing
# but its own artifact. The jobs are idempotent and safe to re-run: the marker write is an upsert
# onto the unique `(repository_id)` index and the job recomputes whatever is wanted when it runs.
#
# ## Why a migration and not a rake task
#
# A committed one-off rake task is exactly the shape that gets discovered and re-run later,
# re-enqueuing the fleet's work for nothing; a migration runs once per database by construction,
# which is the whole property a backfill needs. Enqueueing a job from a migration is unusual and
# deliberate here: the migration is the deploy, the queue is durable, and the alternative —
# waiting for each repository's next ingest — leaves the served regression open for as long as
# that takes.
class BackfillNearDuplicateCensuses < ActiveRecord::Migration[8.1]
  # The queue table exists in every environment this migration can run in — Solid Queue shares
  # the primary database here, per the standing one-database decision in `config/database.yml` —
  # and a row whose repository has vanished between the SELECT and the enqueue is impossible:
  # both statements read the same transaction snapshot. A repository with no runs is excluded at
  # the source, on this file's header's reasoning.
  #
  # The request goes through {NearDuplicateCensus.request_refresh!}, NOT a bare
  # `NearDuplicateCensusJob.perform_later`: the job honours a MARKER — its loop exits when no
  # census row exists or no marker is raised, which is exactly the state of every row this
  # migration runs against, because the table was created one migration earlier and is empty.
  # A bare enqueue would schedule a fleet's worth of jobs that each computed nothing, and every
  # existing repository would read `near_duplicates: null` until its next ingest — the served
  # regression this migration exists to close, re-opened by its own enqueue.
  # `request_refresh!` writes the marker (creating the row) BEFORE the job is scheduled — its
  # own comment states that ordering as the invariant the job's reader depends on — so each
  # backfilled job finds a wanted marker, computes over the data as it stands, and stores the
  # stamped artifact the request path serves.
  def up
    Repository.joins(:test_runs).distinct.find_each do |repository|
      NearDuplicateCensus.request_refresh!(repository.id)
    end
  end

  def down
    # The enqueued jobs are the migration's only effect, and they are idempotent recomputes of a
    # derived artifact — there is nothing to unwind. A repository whose census row was created by
    # a backfill job keeps a correct, stamped artifact; deleting stored answers on the way down
    # would serve `null` for data that exists.
  end
end
