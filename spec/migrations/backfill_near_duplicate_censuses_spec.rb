# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260925002100_backfill_near_duplicate_censuses")

# THE BACKFILL THE DEPLOY RUNS: every repository that has already ingested must be served a real,
# stamped census from the deploy instant — not `null` until its next ingest, which is the served
# regression for data that already exists this migration exists to close.
#
# These examples run the migration's own `up` and DRAIN THE JOBS IT SCHEDULES, because the
# contract is the STORED ROW, not the enqueue. That distinction is the defect this file exists
# against: the job honours a marker (`NearDuplicateCensus.refresh_wanted!` exits when no row
# exists or no marker is raised), so a backfill that enqueued without raising the marker first
# scheduled a fleet's worth of jobs that each computed nothing — green under an enqueue-only pin,
# and every existing repository served `null` anyway. Hence the shape below: the enqueue is
# asserted once, and every behavioral example runs `up` with the queue flushing inline.
RSpec.describe BackfillNearDuplicateCensuses do
  include ActiveJob::TestHelper

  def up!
    migration = described_class.new
    migration.suppress_messages { migration.up }
  end

  # A repository with at least one run, built off the ingest path — the rule every sibling on the
  # census states, and the state the migration's SELECT keys on (`joins(:test_runs)`). The
  # default embedding stand-in resolves the one example; no lexical pair is needed, because what
  # this file pins is that a stamped artifact LANDS, not what it clusters. The identity arguments
  # have no defaults shared with `create_repository`'s, so two calls in one example stay two
  # repositories.
  def repository_with_run(github_uid: "2001", github_handle: "octocat",
                          github_full_name: "octocat/widget")
    user = create_user(github_uid: github_uid, github_handle: github_handle)
    repository = user.repositories.create!(github_full_name: github_full_name)
    payload = Ingest::Payload.new(ingest_payload(specs: [unannotated_spec]).deep_stringify_keys)
    Ingest::RunRecorder.record(repository, payload.test_run_attributes, specs: payload.specs)
    repository
  end

  # @intent: { entity: "BackfillNearDuplicateCensuses", action: "backfill an ingested repository", behavior: "running the migration with the queue flushing leaves every repository that has ingested one stored census with a real payload and its marker honoured", layer: "integration" }
  it "leaves a computed, stamped census for every repository that has ingested" do
    repository = repository_with_run

    # Inline flush: the job runs in the same block the enqueue happens in, which is exactly the
    # deploy's shape — enqueue, then the queue drains — compressed into one step.
    perform_enqueued_jobs { up! }

    census = NearDuplicateCensus.find_by!(repository_id: repository.id)
    expect(census.payload).to be_present
    expect(census.computed_at).to be_present
    expect(census.refresh_wanted_at).to be_nil
  end

  # THE HONEST SERVE, END TO END: the row the backfill leaves is what the overview's ask serves —
  # not the `null` a no-op backfill would have left behind for data that already exists.
  # @intent: { entity: "BackfillNearDuplicateCensuses", action: "serve what the backfill stored", behavior: "after the backfill the overview ask serves a stamped stored block rather than null for a repository whose data predates the deploy", layer: "integration" }
  it "serves the stored block from the overview ask once the backfill has run" do
    repository = repository_with_run

    perform_enqueued_jobs { up! }

    # `serialized_near_duplicates` is the overview's private serve seam; the public surface that
    # reads it is the request spec's job. Here the point is narrower: what the backfill left is
    # what that seam serves, not the `null` a no-op backfill would have left behind.
    served = RepositoryOverview.new(repository: repository, params: { near_duplicates: "true" })
                .send(:serialized_near_duplicates)
    expect(served).to be_present
    expect(served["computed_at"]).to be_present
  end

  # The exclusion is at the source: a repository with no run has no census to backfill, and its
  # honest answer is the never-computed `null` until its first ingest.
  # @intent: { entity: "BackfillNearDuplicateCensuses", action: "skip the never-ingested", behavior: "a repository with no test run gets no census row and no scheduled job from the backfill", layer: "integration" }
  it "does nothing for a repository that has never ingested" do
    repository = create_repository(user: create_user(github_uid: "3003", github_handle: "collab"),
                                   github_full_name: "collab/empty")

    expect { up! }.not_to have_enqueued_job(Ingest::NearDuplicateCensusJob)

    expect(NearDuplicateCensus.where(repository_id: repository.id)).to be_empty
  end

  # @intent: { entity: "BackfillNearDuplicateCensuses", action: "schedule one job per ingested repository", behavior: "the backfill enqueues exactly one census job per repository that has at least one run", layer: "integration" }
  it "enqueues exactly one census job per ingested repository" do
    first = repository_with_run
    second = repository_with_run(github_uid: "2002", github_handle: "hubot",
                                 github_full_name: "hubot/deploys")
    create_repository(user: create_user(github_uid: "3003", github_handle: "collab"),
                      github_full_name: "collab/empty")

    expect { up! }
      .to have_enqueued_job(Ingest::NearDuplicateCensusJob).exactly(:once).with(first.id)
      .and have_enqueued_job(Ingest::NearDuplicateCensusJob).exactly(:once).with(second.id)
  end
end
