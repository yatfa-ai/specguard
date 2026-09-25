# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260925030000_backfill_near_duplicate_census_layers")

# THE RE-TAKE THE DEPLOY RUNS: every repository already serving a stored census must be serving
# one that carries the declared-layer cut — not the layer-free artifact its pre-SPGD-1475 compute
# stored, which serves verbatim until something moves its inputs, and would do so indefinitely for
# a repository that does not happen to ingest again.
#
# The contract is the STORED ROW, not the enqueue, on the precedent the SPGD-1474 backfill spec
# states: the job honours a marker, so an enqueue-only pin would pass a migration that scheduled a
# fleet's worth of no-op jobs. Hence the shape below — the enqueue is asserted once, and the
# behavioral examples run `up` with the queue flushing inline.
RSpec.describe BackfillNearDuplicateCensusLayers do
  # ⭐ THE PROVIDER IS LEXICAL HERE, on the census file family's own rule: the recomputed artifact
  # must hold a CLUSTER for the cut to annotate, and the suite-wide default stub makes two
  # different strings near-orthogonal however alike they read.
  include_context "with lexical embeddings"

  include ActiveJob::TestHelper

  def up!
    migration = described_class.new
    migration.suppress_messages { migration.up }
  end

  # A repository with a stored census in the PRE-deploy shape: computed by `refresh!` and then
  # stripped of the layer keys the way every artifact written before SPGD-1475 ships. Hand-stripping
  # is the only way to hold that state — the live code always writes the keys — and it is exactly
  # the state a deployed row is in. The two specs are a near-duplicate pair declared at DIFFERENT
  # layers, so the recomputed artifact holds a cluster for the cut to annotate.
  def repository_with_pre_layer_census(github_uid: "4001", github_handle: "pre-layer",
                                       github_full_name: "pre-layer/widget")
    user = create_user(github_uid: github_uid, github_handle: github_handle)
    repository = user.repositories.create!(github_full_name: github_full_name)
    payload = Ingest::Payload.new(ingest_payload(specs: [
      annotated_spec(file_path: "spec/models/checkout_spec.rb", line_number: 3,
                     entity: "Checkout", action: "rejects",
                     behavior: "an expired card payment", layer: "unit"),
      annotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 9,
                     entity: "Checkout", action: "rejects",
                     behavior: "an expired card payment outright", layer: "request")
    ]).deep_stringify_keys)
    run = Ingest::RunRecorder.record(repository, payload.test_run_attributes, specs: payload.specs)
    # The resolver is what creates and links the identities the census clusters over — the SPGD-1474
    # backfill spec needs no cluster and skips it; this file's recomputed artifact must hold one.
    Ingest::IdentityResolver.resolve(run)
    NearDuplicateCensus.refresh!(repository)

    census = NearDuplicateCensus.find_by!(repository_id: repository.id)
    stripped = census.payload.deep_dup
    stripped.delete("layer_source")
    stripped["clusters"].each do |cluster|
      cluster.delete("layer_redundancy")
      cluster.delete("layer_groups")
    end
    census.update_columns(payload: stripped)
    census
  end

  # @intent: { entity: "BackfillNearDuplicateCensusLayers", action: "re-take a stored census", behavior: "running the migration with the queue flushing rewrites every stored census so its payload carries the declared-layer cut the pre-deploy compute did not write", layer: "integration" }
  it "rewrites every stored census with the layer keys the pre-deploy artifact lacks" do
    census = repository_with_pre_layer_census
    expect(census.reload.payload).not_to include("layer_source")
    expect(census.payload["clusters"]).to be_present

    perform_enqueued_jobs { up! }

    payload = census.reload.payload
    expect(payload).to include("layer_source" => NearDuplicateClusters::LAYER_SOURCE)
    expect(payload["clusters"].sole).to include("layer_redundancy" => "cross_layer")
    expect(payload["clusters"].sole["layer_groups"].map { |group| group["layer"] })
      .to contain_exactly("request", "unit")
  end

  # The marker is the machinery, and it must be RAISED — a bare enqueue would schedule jobs that
  # honour nothing, the exact defect the SPGD-1474 backfill spec exists against.
  # @intent: { entity: "BackfillNearDuplicateCensusLayers", action: "raise the marker", behavior: "the migration enqueues exactly one census job per repository with runs, through the marker the job honours", layer: "integration" }
  it "enqueues exactly one census job per repository with runs" do
    first = repository_with_pre_layer_census
    second = repository_with_pre_layer_census(github_uid: "4002", github_handle: "re-take",
                                              github_full_name: "re-take/deploys")

    expect { up! }
      .to have_enqueued_job(Ingest::NearDuplicateCensusJob).exactly(:once).with(first.repository_id)
      .and have_enqueued_job(Ingest::NearDuplicateCensusJob).exactly(:once).with(second.repository_id)
  end

  # @intent: { entity: "BackfillNearDuplicateCensusLayers", action: "skip the never-ingested", behavior: "a repository with no test run gets no census row and no scheduled job from the re-take", layer: "integration" }
  it "does nothing for a repository that has never ingested" do
    repository = create_repository(user: create_user(github_uid: "4003", github_handle: "empty"),
                                   github_full_name: "empty/suite")

    expect { up! }.not_to have_enqueued_job(Ingest::NearDuplicateCensusJob)
    expect(NearDuplicateCensus.where(repository_id: repository.id)).to be_empty
  end
end
