# frozen_string_literal: true

require "rails_helper"

# The stored near-duplicate census: the refresh marker (`request_refresh!`, requested by the
# ingest path and by run deletion), the job-side loop
# that honours it (`refresh_wanted!`), the compute-and-store unit (`refresh!`), and the serving
# shape (`#serialized`). `NearDuplicateClusters` itself is the model spec next door — clustering
# semantics are untouched by SPGD-1474 and asserted nowhere here; what THIS file owns is that the
# stored artifact equals what that object computes, is stamped with when it was taken and which run
# it was weighed on, and that the marker turns a shard storm of refresh requests into one compute.
#
# ⭐ THE PROVIDER IS LEXICAL HERE, on this file family's own rule: the suite-wide stub makes two
# different strings near-orthogonal however alike they read, so the "a cluster is actually stored"
# assertions below would pass or fail for reasons that have nothing to do with the threshold
# without a stand-in that gives two readings of one behaviour a cosine above the floor.
RSpec.describe NearDuplicateCensus do
  include_context "with lexical embeddings"

  let(:repository) { create_repository }

  let(:expired) { "Checkout rejects an expired card" }
  let(:outright) { "Checkout rejects an expired card outright" }

  def ingest(specs, commit_sha: "feedfacecafe0001", **attrs)
    payload = Ingest::Payload.new(
      { "commit_sha" => commit_sha, "branch" => "main", "duration_seconds" => 60.0,
        "specs" => specs.map(&:deep_stringify_keys) }.merge(attrs.deep_stringify_keys)
    )
    raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

    run = Ingest::RunRecorder.record(repository, payload.test_run_attributes, specs: payload.specs)
    Ingest::IdentityResolver.resolve(run)
    run
  end

  def near_duplicate_pair(commit_sha: "feedfacecafe0001")
    ingest([unannotated_spec(file_path: "spec/models/checkout_spec.rb", line_number: 3,
                             name: expired, id: "./spec/models/checkout_spec.rb[1:1]",
                             duration: 0.2),
            unannotated_spec(file_path: "spec/models/checkout_spec.rb", line_number: 9,
                             name: outright, id: "./spec/models/checkout_spec.rb[2:1]",
                             duration: 0.4)],
           commit_sha: commit_sha)
  end

  describe ".request_refresh!" do
    # @intent: { entity: "NearDuplicateCensus", action: "request refresh", behavior: "requesting a refresh creates the repository one row with the marker set and schedules the census job for the repository id", layer: "unit" }
    it "creates the repository's one row, raises the marker, and schedules the job" do
      expect { described_class.request_refresh!(repository.id) }
        .to change(described_class, :count).by(1)
        .and have_enqueued_job(Ingest::NearDuplicateCensusJob).with(repository.id)

      census = described_class.sole
      expect(census.repository_id).to eq(repository.id)
      expect(census.refresh_wanted_at).to be_present
      # The row is marker plumbing until the first compute runs: no payload, no stamp, and
      # `#serialized` refuses it — "wanted" is not "computed".
      expect(census.payload).to be_nil
      expect(census.computed_at).to be_nil
    end

    # One POST is one shard, not one run, so a sharded delivery requests a refresh N times over
    # one repository. The row converges (the unique index is the arbiter) and the marker moves —
    # it never duplicates, and it never disturbs a stored artifact.
    # @intent: { entity: "NearDuplicateCensus", action: "converge requests", behavior: "a second refresh request reuses the repository existing row, moves only the marker, and leaves any stored artifact byte-identical", layer: "unit" }
    it "converges on the existing row and moves only the marker" do
      near_duplicate_pair
      described_class.refresh!(repository)
      stored = described_class.find_by!(repository_id: repository.id)

      expect { described_class.request_refresh!(repository.id) }
        .not_to change(described_class, :count)

      expect(stored.reload.payload).to eq(stored.payload)
      expect(stored.computed_at).to eq(stored.reload.computed_at)
      expect(stored.refresh_wanted_at).to be_present
    end
  end

  describe ".refresh!" do
    # THE CONTRACT THE WHOLE TICKET RESTS ON: the stored artifact is what `NearDuplicateClusters`
    # computes for the same data — read field by field off the LIVE object, never re-derived, so
    # the serve path can promise stored-equals-live rather than hope for it. (The stored payload
    # reads back with string keys — json round-trips — so the expectation stringifies its own.)
    # @intent: { entity: "NearDuplicateCensus", action: "store the live computation", behavior: "refreshing stores a payload whose every summary figure equals the live NearDuplicateClusters computation over the same data", layer: "unit" }
    it "stores exactly what the live computation returns for the same data" do
      near_duplicate_pair

      described_class.refresh!(repository)

      stored = described_class.find_by!(repository_id: repository.id)
      live = NearDuplicateClusters.for(repository)

      expected = {
        similarity_floor: live.similarity_floor,
        similarity_basis: live.similarity_basis,
        cluster_count: live.cluster_count,
        truncated: live.truncated?,
        saturated_identity_count: live.saturated_identity_count,
        unresolved_count: live.unresolved_count,
        recorded_count: live.recorded_count,
        identity_count: live.identity_count,
        clustered_identity_count: live.clustered_identity_count,
        clustered_timed_count: live.clustered_timed_count,
        clustered_example_count: live.clustered_example_count
      }.deep_stringify_keys
      expect(stored.payload).to include(expected)

      # And the clusters themselves, not just the caption: one cluster, two members, and the
      # similarity range rounded by the object's own method.
      expect(stored.payload["clusters"].size).to eq(live.clusters.size)
      stored_cluster = stored.payload["clusters"].sole
      live_cluster = live.clusters.sole
      expect(stored_cluster["member_count"]).to eq(live_cluster.member_count)
      expect(stored_cluster["example_count"]).to eq(live_cluster.example_count)
      expect(stored_cluster["total_seconds"]).to eq(live_cluster.total_seconds)
      expect(stored_cluster["similarity_range"]).to eq(live_cluster.similarity_range)
    end

    # The stamps ride the same write as the figures — a census whose stamp could disagree with its
    # payload is a dated lie, and the whole point of storing the stamp beside the payload is that
    # one writer sets both.
    # @intent: { entity: "NearDuplicateCensus", action: "stamp the artifact", behavior: "refreshing stores computed_at as the moment of the write and weighed_run_id as the run the live computation weighed", layer: "unit" }
    it "stamps the artifact with when it was taken and which run it was weighed on" do
      run = near_duplicate_pair

      expect { described_class.refresh!(repository) }
        .to change(described_class, :count).by(1)

      stored = described_class.find_by!(repository_id: repository.id)
      expect(stored.computed_at).to be_present
      expect(stored.weighed_run_id).to eq(repository.latest_test_run.id).and eq(run.id)
    end

    # THE HONEST EMPTY RANKING IS A STORED ROW, NOT AN ABSENCE. A repository whose every test
    # reads differently computes a real census — empty `clusters`, live population counts — and
    # it must be stored as one, because "computed, and nothing reads alike" is a finding while
    # "no census exists yet" is a silence, and only the payload's presence tells them apart.
    # @intent: { entity: "NearDuplicateCensus", action: "store the empty ranking", behavior: "an all-unique suite stores a real census with empty clusters and a population behind them, and a never-ingested repository stores the zero populations with a null weighed run", layer: "unit" }
    it "stores the no-clusters state as a real, stamped artifact" do
      ingest([unannotated_spec(file_path: "spec/models/only_spec.rb", line_number: 3,
                               name: "Shipping calculates a delivery estimate")])
      described_class.refresh!(repository)
      stored = described_class.find_by!(repository_id: repository.id)

      expect(stored.payload["clusters"]).to eq([])
      expect(stored.payload["cluster_count"]).to eq(0)
      expect(stored.payload["identity_count"]).to eq(1)
      expect(stored.payload["recorded_count"]).to eq(1)
      expect(stored.weighed_run_id).to eq(repository.latest_test_run.id)
    end

    # @intent: { entity: "NearDuplicateCensus", action: "census the unrun", behavior: "a never-ingested repository stores the zero-population census with weighed_run_id null rather than refusing to compute", layer: "unit" }
    it "stores the zero-population census for a repository that never ingested" do
      described_class.refresh!(repository)

      stored = described_class.find_by!(repository_id: repository.id)
      expect(stored.payload["cluster_count"]).to eq(0)
      expect(stored.payload["recorded_count"]).to eq(0)
      expect(stored.payload["identity_count"]).to eq(0)
      expect(stored.weighed_run_id).to be_nil
    end
  end

  describe ".refresh_wanted!" do
    # The job-side happy path: a wanted marker is honoured by one compute, and the marker is
    # CLEARED by the honour — a flag that stayed set would recompute forever.
    # @intent: { entity: "NearDuplicateCensus", action: "honour the marker", behavior: "a wanted marker is honoured by exactly one compute and then cleared, so the loop terminates", layer: "unit" }
    it "computes once for a wanted marker and clears it" do
      near_duplicate_pair
      described_class.request_refresh!(repository.id)
      marker = described_class.find_by!(repository_id: repository.id).refresh_wanted_at

      described_class.refresh_wanted!(repository)

      census = described_class.find_by!(repository_id: repository.id)
      expect(census.payload).to be_present
      expect(census.refresh_wanted_at).to be_nil
      # The compare-and-clear predicate is an exact-timestamp match; the marker that was cleared is
      # the marker that was read, which is what makes the debounce below sound.
      expect(marker).to be_present
    end

    # @intent: { entity: "NearDuplicateCensus", action: "skip unhonoured work", behavior: "no marker means no compute, so a scheduled job whose flag was already honoured exits without doing the work twice", layer: "unit" }
    it "does nothing when no refresh is wanted" do
      near_duplicate_pair
      described_class.refresh!(repository)

      expect(described_class).not_to receive(:refresh!)

      described_class.refresh_wanted!(repository)
    end

    # THE DEBOUNCE. A marker that changes WHILE the compute is running means an ingest landed and
    # the artifact just written is already stale — so the loop takes the census again and exits
    # only when a compute finishes with the marker still holding its own snapshot. Twenty shards
    # requesting a refresh over one ingest land as one compute over the settled state, not twenty.
    # @intent: { entity: "NearDuplicateCensus", action: "recompute over a mid-compute ingest", behavior: "a marker that changes during the compute forces a second compute, and the loop exits once a compute finishes with its own snapshot still current", layer: "unit" }
    it "recomputes when an ingest lands while the census is being taken" do
      near_duplicate_pair
      described_class.request_refresh!(repository.id)

      computes = 0
      allow(described_class).to receive(:refresh!).and_wrap_original do |original, repo|
        # The FIRST compute runs while a second ingest lands — which raises the marker again, the
        # exact race the compare-and-clear exists for. The second compute finds the settled state
        # and the loop exits.
        if (computes += 1) == 1
          ingest([unannotated_spec(file_path: "spec/models/shipping_spec.rb", line_number: 3,
                                   name: "Shipping calculates a delivery estimate",
                                   id: "./spec/models/shipping_spec.rb[1:1]")],
                 commit_sha: "feedfacecafe0002")
          described_class.request_refresh!(repository.id)
        end
        original.call(repo)
      end

      described_class.refresh_wanted!(repository)

      expect(computes).to eq(2)
      census = described_class.find_by!(repository_id: repository.id)
      expect(census.refresh_wanted_at).to be_nil
      # And the artifact is the POST-storm state, not the mid-compute one.
      expect(census.payload["identity_count"]).to eq(3)
    end

    # @intent: { entity: "NearDuplicateCensus", action: "exit on the cleared row", behavior: "a repository whose census row was destroyed mid-compute ends the loop without recomputing", layer: "unit" }
    it "exits cleanly when the census row disappears mid-loop" do
      near_duplicate_pair
      described_class.request_refresh!(repository.id)
      allow(described_class).to receive(:refresh!) do
        described_class.find_by!(repository_id: repository.id).destroy!
      end

      expect { described_class.refresh_wanted!(repository) }.not_to raise_error
    end
  end

  describe "#serialized" do
    # The serve path serves this — the stored figures with the two stamps merged, and never
    # anything recomputed.
    # @intent: { entity: "NearDuplicateCensus", action: "serve the stored block", behavior: "serialized returns the stored payload with computed_at as iso8601 and weighed_run_id merged at the top level", layer: "unit" }
    it "merges the stamps onto the stored payload" do
      near_duplicate_pair
      described_class.refresh!(repository)
      census = described_class.find_by!(repository_id: repository.id)

      served = census.serialized

      expect(served["computed_at"]).to eq(census.computed_at.iso8601)
      expect(served["weighed_run_id"]).to eq(census.weighed_run_id)
      expect(served["cluster_count"]).to eq(census.payload["cluster_count"])
      # The payload itself carries neither stamp: one writer, one column, one merge point — the
      # stamps cannot be stored twice and drift apart.
      expect(census.payload).not_to include("computed_at", "weighed_run_id")
    end

    # A row created by the marker before its first compute holds no artifact, and serving it would
    # render "not computed yet" as nulls a consumer could read as a census of nothing.
    # @intent: { entity: "NearDuplicateCensus", action: "refuse the never-computed", behavior: "a census row with no payload serializes to nil so the serve path answers nothing rather than an unstamped block", layer: "unit" }
    it "refuses to serve a never-computed row" do
      described_class.request_refresh!(repository.id)
      census = described_class.find_by!(repository_id: repository.id)

      expect(census.payload).to be_nil
      expect(census.serialized).to be_nil
    end
  end
end
