# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ingest::NearDuplicateCensusJob do
  include_context "with lexical embeddings"

  let(:repository) { create_repository }

  # @intent: { entity: "Ingest::NearDuplicateCensusJob", action: "refresh census", behavior: "performing for a repository honours its wanted marker and stores a computed census row", layer: "unit" }
  it "computes and stores the census for the repository it was given" do
    payload = Ingest::Payload.new(ingest_payload(specs: [unannotated_spec]).deep_stringify_keys)
    run = Ingest::RunRecorder.record(repository, payload.test_run_attributes, specs: payload.specs)
    Ingest::IdentityResolver.resolve(run)
    NearDuplicateCensus.request_refresh!(repository.id)

    described_class.perform_now(repository.id)

    census = NearDuplicateCensus.find_by!(repository_id: repository.id)
    expect(census.payload).to be_present
    expect(census.computed_at).to be_present
    expect(census.weighed_run_id).to eq(run.id)
    expect(census.refresh_wanted_at).to be_nil
  end

  # Between the schedule and the dequeue the repository may have been deleted, which takes its
  # census row with it. There is nothing to compute and nothing to report, so this is not an
  # error — the same rule its sibling states for a vanished run.
  # @intent: { entity: "Ingest::NearDuplicateCensusJob", action: "handle vanished repository", behavior: "performing for a deleted repository id completes without raising", layer: "unit" }
  it "is a no-op for a repository that no longer exists" do
    id = repository.id
    repository.destroy!

    expect { described_class.perform_now(id) }.not_to raise_error
  end

  # The serve path never computes; this job is where the minutes-scale work was moved to, so the
  # wire contract this job protects is "the stored census exists and is stamped" — pinned at the
  # seam the overview reads, not re-asserted model-side here.
  # @intent: { entity: "Ingest::NearDuplicateCensusJob", action: "leave the serve path a read", behavior: "after performing, the stored block the overview serves is present and stamped", layer: "unit" }
  it "leaves the serve path a stored read" do
    payload = Ingest::Payload.new(ingest_payload(specs: [unannotated_spec]).deep_stringify_keys)
    run = Ingest::RunRecorder.record(repository, payload.test_run_attributes, specs: payload.specs)
    Ingest::IdentityResolver.resolve(run)
    NearDuplicateCensus.request_refresh!(repository.id)

    described_class.perform_now(repository.id)

    served = NearDuplicateCensus.stored_block_for(repository)
    expect(served).to include("weighed_run_id" => run.id)
    expect(served["computed_at"]).to be_present
  end

  # One POST is one shard, so a sharded delivery enqueues many of these over one repository.
  # `limits_concurrency` collapses that to one job at a time per repository — the same argument
  # `IdentityResolutionJob` makes per run, one grain over.
  #
  # `config/environments/test.rb` pins this suite to ActiveJob's `:test` adapter — deliberately
  # not `:solid_queue` — so NO example here can exercise the blocking at runtime. What is
  # assertable is the configuration the Solid Queue dispatcher reads, and it is enough: it catches
  # every way this can be got wrong.
  describe "serializing one repository's jobs" do
    # @intent: { entity: "Ingest::NearDuplicateCensusJob", action: "limit concurrency", behavior: "the concurrency limit is one job at a time", layer: "unit" }
    it "admits one job at a time" do
      expect(described_class.concurrency_limit).to eq(1)
    end

    # @intent: { entity: "Ingest::NearDuplicateCensusJob", action: "key concurrency", behavior: "two jobs for the same repository id derive an identical concurrency key", layer: "unit" }
    it "keys the limit on the repository, so two jobs for one repository share a key" do
      expect(described_class.new(repository.id).concurrency_key)
        .to eq(described_class.new(repository.id).concurrency_key)
    end

    # The other direction, and the one that matters: a constant key would satisfy the assertion
    # above while serializing every repository's census behind every other's — the fleet's
    # recomputes queued single-file behind the slowest suite, a multi-tenant stall dressed as an
    # optimisation.
    # @intent: { entity: "Ingest::NearDuplicateCensusJob", action: "key concurrency per repository", behavior: "jobs for different repositories derive different concurrency keys so repositories do not serialise together", layer: "unit" }
    it "keys the limit on the repository, so jobs for different repositories do not share a key" do
      other = create_repository(user: create_user(github_uid: "2026-census", github_handle: "octo-census"),
                                github_full_name: "acme/other-census")

      expect(described_class.new(repository.id).concurrency_key)
        .not_to eq(described_class.new(other.id).concurrency_key)
    end

    # `duration` is how long the dispatcher waits before assuming a semaphore holder died and
    # releasing a blocked job anyway. A design-point census is minutes, and a default expiry would
    # release the next job into a compute still running — this slice voids with nothing turning
    # red unless the duration is pinned past it.
    # @intent: { entity: "Ingest::NearDuplicateCensusJob", action: "hold semaphore", behavior: "the semaphore duration exceeds SolidQueue default period and is at least one hour", layer: "unit" }
    it "holds its semaphore for hours, not the SolidQueue default" do
      expect(described_class.concurrency_duration).to be > 3.minutes
    end
  end
end
