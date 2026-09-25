# frozen_string_literal: true

module Ingest
  # The stored-census compute, shared by both write paths that move the census's inputs:
  # recomputes the repository's near-duplicate census and stores it for the request path to serve.
  # Requested by {IdentityResolutionJob} after its resolve returns — the earliest moment the
  # census's inputs (`spec_identities`, `spec_observations`, and the repository's newest run as
  # the weighed run) are frozen for the run that just landed — and by {RunsController#destroy}
  # once a deleted run and its observations are gone (the delete can move `latest_test_run`, the
  # weighed run a live computation would now name) — and executed here, out of band, so
  # a minutes-scale computation never sits behind a request again.
  #
  # Thin on purpose — {NearDuplicateCensus} holds the work (`request_refresh!` raised the flag and
  # scheduled this job; `refresh_wanted!` is the loop that honours it, debounces the shard storm,
  # and stamps the stored artifact). The class comment there owns the freshness contract: a
  # request arriving mid-recompute serves the PREVIOUS stored census with its stamp, and nothing
  # on the request path ever computes.
  #
  # == No retry policy, for the reason its sibling states and one more
  #
  # No `retry_on`, no `discard_on`, on {IdentityResolutionJob}'s precedent: what re-does the work
  # is the NEXT WRITE that moves the inputs — the next ingest, whose resolution job requests a
  # fresh census, or the next run deletion, which requests one itself — over whatever state it
  # finds — so a census job lost to a database blip or a deploy costs the
  # freshness of the stored artifact, never its correctness, and the next write heals it. The
  # stored census between those points is the previous artifact with its own stamp, which is
  # exactly what the freshness contract serves.
  #
  # == Why one repository's jobs run one at a time
  #
  # `request_refresh!` schedules one of these per identity-resolution job — and once per run
  # deletion — and one POST is one shard, not one run — a sharded delivery, or a burst of junk-run
  # deletions, schedules many. The marker loop in
  # {NearDuplicateCensus.refresh_wanted!} already collapses the WORK to the last wanted state, but
  # without a concurrency limit several of these jobs could run the compute CONCURRENTLY — N
  # simultaneous minutes-scale censuses over one repository, each racing the same row's update.
  # `limits_concurrency` keyed on the repository serializes them: the first computes while the
  # rest are blocked, each blocked job finds the flag already honoured when it is released, and
  # exits without recomputing. Different repositories stay fully parallel — a constant key here
  # would serialize the fleet's censuses behind each other.
  #
  # `duration:` bounds a STUCK semaphore, not an expected runtime, exactly as its sibling argues:
  # a 20,000-identity census is minutes, and a default expiry would release the next job into a
  # compute still running. Hours, so expiry means "something is wrong", never "this suite is
  # large".
  #
  # A repository that no longer exists is not an error. Between the schedule and the dequeue its
  # row may have been deleted, which takes its census with it; there is nothing to compute and
  # nothing to report.
  class NearDuplicateCensusJob < ApplicationJob
    queue_as :default

    limits_concurrency to: 1, key: ->(repository_id) { repository_id }, duration: 6.hours

    def perform(repository_id)
      repository = Repository.find_by(id: repository_id)
      return if repository.nil?

      NearDuplicateCensus.refresh_wanted!(repository)
    end
  end
end
