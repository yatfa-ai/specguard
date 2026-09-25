# frozen_string_literal: true

# THE STORED NEAR-DUPLICATE CENSUS — the persisted answer to "where in the suite is the same
# logic tested more than once, and what does it cost", written once per ingest and served stored,
# so the main path answers in milliseconds instead of running a minutes-scale computation behind
# a request.
#
# ## The census moved off the request path, and this class is why that is safe
#
# `NearDuplicateClusters` was computed LIVE on every `?near_duplicates=` ask. Its own class
# comment carries the measurements: linear in the suite, seconds at a few thousand identities,
# tens of seconds extrapolated at the 20,000-identity design point — against an agent bridge
# whose default deadline is thirty seconds. Every agent call failed, retries included, so the
# product's core question was unreachable from the consumer it was built for.
#
# The fix was always available, because the census is a pure derivative of ingested data. Its
# three inputs — the repository's `spec_identities` (which the clustering reads), its
# `spec_observations` (which the weight figures join through), and `repository.latest_test_run`
# (the weighed run) — change only at ingest. So the computation is scheduled by the ingest path
# ({Ingest::IdentityResolutionJob} requests a refresh once identity resolution has run), executed
# by {Ingest::NearDuplicateCensusJob}, and stored; `RepositoryOverview#serialized_near_duplicates`
# serves what is stored. Between ingests the inputs are frozen, so **the stored census equals what
# a live computation would return — byte-identical, not approximately**: the writer serializes the
# very object the live path would have built, and the serve path returns those bytes verbatim.
# Nothing re-derives anything on the way out.
#
# A request arriving between a completed ingest and the finished recompute serves the PREVIOUS
# stored census with its own `computed_at` stamp — never a live computation, never an unstamped
# answer. That is the freshness contract, and it is why there is no live fallback anywhere in
# `refresh!`'s callers: a fallback would reintroduce the minutes-scale request path this table
# exists to remove.
#
# == The census is parameterless, which is what makes precompute whole rather than partial
#
# From the consumer's side the ask is presence-only: threshold, limit, neighbour cap and the
# weighed run are the server's own constants and defaults (`NearDuplicateClusters::SIMILARITY`,
# `LIMIT`, `NEIGHBOURS`, `repository.latest_test_run`). There is no consumer-supplied knob for one
# stored artifact to disagree with another about, so ONE row per repository holds THE answer —
# which is what the unique `(repository_id)` index states, and what a per-consumer computation
# would have made impossible to precompute.
#
# == The recompute marker, and why one sharded ingest costs one census
#
# `request_refresh!` is called once per identity-resolution job, and one POST is one shard, not
# one run — a twenty-shard delivery requests a refresh twenty times. Computing on every request
# would spend twenty censuses per ingest, each minutes long, on a three-thread worker pool shared
# with identity resolution itself. So the request only RAISES A FLAG (`refresh_wanted_at`) and
# schedules one job; the job computes, then clears the flag **only if it still holds the value it
# read when it started**. A flag that changed mid-compute means an ingest landed while the census
# was being taken — the artifact just written is already stale — so the job loops and computes
# again over the newer state, and exits the moment a compute finishes with the flag still holding
# its own snapshot. Under a burst of ingests this self-debounces to one census per compute-length
# of quiet rather than one per request; under a paused ingest it is exactly one census.
#
# The marker is also the honest answer to "is a recompute in flight": a set flag beside a stored
# row means the row just served is the previous census and a newer one is being taken — which is
# precisely the state the freshness contract above describes, readable instead of guessed.
#
# == What is stored, and what is a column beside it
#
# `payload` is the serialized census — the same keys, figures and clusters the request path used
# to assemble live, minus the two stamps, which are columns: `weighed_run_id` (which run the
# weight figures were measured in) and `computed_at` (when the artifact was taken). Stamps are
# columns so the serving side can merge them in one place and no writer can store figures whose
# stamp disagrees with them. `payload` nil means never computed — a row created by the marker
# before its first census ran — and `#serialized` refuses to serve it: nil payload is plumbing,
# not an answer, and "not computed yet" must not render as zeros.
class NearDuplicateCensus < ApplicationRecord
  belongs_to :repository

  class << self
    # The stored block for ONE repository's overview ask, or `nil` when there is nothing stored.
    #
    # `nil` is served, never a live computation and never zeros: it is the honest answer for a
    # repository whose census has not been computed yet — a repository that has never ingested
    # (its first ingest schedules the first census), or one read in the window between this table
    # shipping and its backfill landing. A repository whose every test reads differently is NOT
    # this state: its census is a stored row with an empty `clusters` array and real population
    # counts, and it serves as the finding it is.
    def stored_block_for(repository)
      find_by(repository_id: repository.id)&.serialized
    end

    # THE INGEST-SIDE REQUEST: mark the stored census stale and schedule the job that takes a new
    # one. Called from {Ingest::IdentityResolutionJob} once identity resolution has run — the
    # earliest moment the census's inputs are settled for the run that just landed. Computing
    # before identity resolution finishes would store a census over half-matched identities that
    # no live computation would ever return, which is exactly the byte-identity property above.
    #
    # `create_or_find_by!` converges on one row when shards race (the unique index is the
    # arbiter), and the marker is written BEFORE the job is scheduled — a job that found no
    # marker would honour nothing and exit, so the flag must exist by the time its reader can run.
    def request_refresh!(repository_id)
      create_or_find_by!(repository_id: repository_id)
        .update_column(:refresh_wanted_at, Time.current)

      Ingest::NearDuplicateCensusJob.perform_later(repository_id)
    end

    # THE JOB-SIDE LOOP: while a refresh is wanted, take one census and store it; stop when a
    # compute finishes with the marker still holding the value it read at that compute's start.
    # See "The recompute marker" above for why the compare-and-clear is the debounce and the exit.
    #
    # The marker is RE-READ from the database at the top of every iteration, never trusted from a
    # memo: an object loaded before a compute carries the flag as it WAS, and a loop that exited
    # on that memo would spin once more over a marker it had already honoured — or miss one that
    # had moved. A repository that stops existing between the schedule and the run is not an
    # error — the same rule {Ingest::IdentityResolutionJob} states for a vanished run — and
    # neither is a row whose marker was honoured by the compute ahead of this job: both break the
    # loop at the same re-read.
    def refresh_wanted!(repository)
      loop do
        census = find_by(repository_id: repository.id)
        break if census.nil? || census.refresh_wanted_at.nil?

        wanted = census.refresh_wanted_at
        refresh!(repository)

        # `update_all` on the predicate, not a read-modify-write of the flag: the WHERE is the
        # compare, the affected-row count is the verdict, and nothing between the compute and the
        # clear can be lost to a concurrent writer.
        break if where(id: census.id, refresh_wanted_at: wanted)
                .update_all(refresh_wanted_at: nil).positive?

        # The marker moved while the compute ran — an ingest landed mid-census — so loop and take
        # the census again over the newer state.
      end
    end

    # Take the census NOW and store it — the unit the loop above runs. Unconditional: it is
    # called only behind a wanted marker, and the marker logic is what decides how often that is.
    #
    # `NearDuplicateClusters.for(repository)` is called with `run:` defaulted, exactly as the
    # request path always did — the repository's newest run is the weighed run, and a stored
    # artifact weighed on anything else would disagree with the live computation it promises to
    # equal. The object's `validate_run!` still guards the caption half at the write, where a
    # violated tenant boundary is a caller's bug; it guards there rather than here because the
    # serve path no longer constructs the object at all.
    def refresh!(repository)
      clusters = NearDuplicateClusters.for(repository)

      find_or_initialize_by(repository_id: repository.id).update!(
        weighed_run_id: clusters.weighed_run_id,
        computed_at: Time.current,
        payload: snapshot_payload(clusters)
      )
    end

    private

    # THE SERIALIZED CENSUS — byte-for-byte what the request path used to assemble live, moved
    # here wholesale from `RepositoryOverview` when the serve path stopped computing. Every key
    # keeps its shape and its meaning; `weighed_run_id` is the one departure, and it is a
    # promotion, not a deletion: it is a column beside the payload now, set by the same write, so
    # the figures and the run they were weighed on cannot be stored apart.
    #
    # A stored payload is written once per ingest and read whole; it is never queried by content,
    # so it is a jsonb column and not a graph of tables. Storing the raw PAIR read instead would
    # grow this table with `identities × k` rows per repository — the census's answer is the
    # clusters, and the clusters are what is kept.
    def snapshot_payload(clusters)
      {
        similarity_floor: clusters.similarity_floor,
        similarity_basis: clusters.similarity_basis,
        cluster_count: clusters.cluster_count,
        truncated: clusters.truncated?,
        saturated_identity_count: clusters.saturated_identity_count,
        unresolved_count: clusters.unresolved_count,
        recorded_count: clusters.recorded_count,
        identity_count: clusters.identity_count,
        clustered_identity_count: clusters.clustered_identity_count,
        clustered_timed_count: clusters.clustered_timed_count,
        clustered_example_count: clusters.clustered_example_count,
        clusters: clusters.clusters.map { |cluster| cluster_payload(cluster) }
      }
    end

    # ONE cluster of tests that read alike, with the figures the ranking is built on — as numbers
    # rather than as the sentences `NearDuplicateClusters::Cluster#duration_label` would build.
    # Per the class comment's ⭐ sections, `member_count` and `example_count` are read at two
    # different grains and served as two different numbers; `unobserved_members` discloses that
    # the member list holds an identity the weighed run did not observe (deleted, renamed, not
    # selected) rather than leaving it to be inferred from a small sum; `similarity_range` is the
    # object's `[strongest, weakest]` pair, both already rounded by the method that owns the
    # rounding, because membership is transitive while similarity is not and the gap between the
    # two edges is the point.
    def cluster_payload(cluster)
      {
        signal_source: cluster.signal_source,
        member_count: cluster.member_count,
        example_count: cluster.example_count,
        total_seconds: cluster.total_seconds,
        timed_count: cluster.timed_count,
        similarity_range: cluster.similarity_range,
        unobserved_members: cluster.unobserved_members?,
        members: cluster.members.map do |member|
          { text: member.text, file_path: member.file_path, line_number: member.line_number,
            example_count: member.example_count, total_seconds: member.total_seconds }
        end
      }
    end
  end

  # THE SERVED BLOCK — the stored census with its two stamps merged in. The stamp keys ride at
  # the top level beside the figures, which is the contract the block has always had for
  # `weighed_run_id`; `computed_at` joins it as the freshness half, because a census answer
  # without when it was taken is a claim about a suite state nothing dates.
  #
  # Refuses a never-computed row: `payload` nil is marker plumbing (see the class comment), and
  # serving it would render `null` figures as if they were a census of nothing.
  def serialized
    return nil if payload.nil?

    payload.merge("weighed_run_id" => weighed_run_id,
                  "computed_at" => computed_at.iso8601)
  end
end
