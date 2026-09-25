# frozen_string_literal: true

require "rails_helper"

# SPGD-812: deleting ONE run from the "Recent runs" panel. Until this action existed a junk row
# (a cancelled job's half-sized shard row) was permanent — the only way to remove it was to
# destroy the whole repository.
#
# What these examples hold down is that the delete is surgical and honest: exactly the named row
# and its per-run children go, the durable things it pointed at (intents, identities) survive
# nullified, nothing of any other run or repository is touched, and the refusal shapes match the
# repository-delete path — a non-member learns nothing (404), a member without `repo.delete`
# gets the 403 every other `:repo_delete` gate gives.
RSpec.describe "Deleting a test run", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def create_observation(test_run, shard: nil)
    test_run.spec_observations.create!(
      repository: test_run.repository,
      file_path: "spec/models/invoice_spec.rb",
      line_number: 12,
      status: "annotated"
    ).tap { |o| o.update!(test_run_shard: shard) if shard }
  end

  describe "the delete itself" do
    # @intent: {"entity": "TestRun", "action": "delete one run", "behavior": "the delete removes exactly the named run, redirects to the repository page, and the flash names Deleted run a1b2c3d (main)", "layer": "request"}
    it "removes exactly that run and redirects to the repository page, naming sha and branch" do
      run = create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6", branch: "main")

      delete repository_run_path(repository, run)

      expect(response).to redirect_to(repository_path(repository))
      expect { run.reload }.to raise_error(ActiveRecord::RecordNotFound)
      follow_redirect!
      expect(response.body).to include("Deleted run a1b2c3d (main)")
    end

    # @intent: {"entity": "TestRun", "action": "word absent branch", "behavior": "deleting a run that reported no branch confirms with Deleted run a1b2c3d (branch not reported) rather than an empty paren", "layer": "request"}
    it "says 'branch not reported' rather than a blank when the run reported no branch" do
      run = create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6", branch: nil)

      delete repository_run_path(repository, run)
      follow_redirect!

      expect(response.body).to include("Deleted run a1b2c3d (branch not reported)")
    end

    # @intent: {"entity": "TestRun", "action": "nullify durable rows", "behavior": "the delete destroys the shard and the observation but leaves the spec intent and the last-seen identity alive with their run foreign keys nulled", "layer": "request"}
    it "deletes shards and observations but nullifies intents and last-seen identities" do
      run = create_test_run(repository: repository, ci_run_id: "ci-1")
      shard = run.test_run_shards.create!(shard_id: "1", total_specs_count: 5)
      observation = create_observation(run, shard: shard)
      intent = run.repository.spec_intents.create!(
        file_path: "spec/models/invoice_spec.rb", line_number: 12, entity: "Invoice",
        action: "finalize", behavior: "locks the line items", layer: "unit", test_run: run
      )
      identity = create_spec_identity(repository: repository)
      identity.update!(last_seen_test_run: run)

      delete repository_run_path(repository, run)

      expect(TestRunShard.exists?(shard.id)).to be false
      expect(SpecObservation.exists?(observation.id)).to be false
      # Durable rows survive, nullified — the cascade `TestRun` declares is the whole argument.
      expect(SpecIntent.exists?(intent.id)).to be true
      expect(intent.reload.test_run_id).to be_nil
      expect(SpecIdentity.exists?(identity.id)).to be true
      expect(identity.reload.last_seen_test_run_id).to be_nil
    end

    # @intent: {"entity": "TestRun", "action": "touch only that run", "behavior": "deleting one run leaves the repository's other run and another repository's run intact, the repository keeping exactly one run", "layer": "request"}
    it "touches no other run of the repository and no row of another repository" do
      other_repository = create_repository(user: @user, github_full_name: "acme/other")
      other_repo_run = create_test_run(repository: other_repository)
      other_run = create_test_run(repository: repository, commit_sha: "0f0f0f0f0f0f")
      victim = create_test_run(repository: repository)

      delete repository_run_path(repository, victim)

      expect(TestRun.exists?(other_run.id)).to be true
      expect(TestRun.exists?(other_repo_run.id)).to be true
      expect(repository.test_runs.count).to eq(1)
    end

    # @intent: {"entity": "TestRun", "action": "advance latest run", "behavior": "deleting the newest run moves latest_test_run to the remaining older run under the shared created_at ordering", "layer": "request"}
    it "advances latest_test_run to the next-newest run by the shared ordering, tie-break included" do
      oldest = create_test_run(repository: repository, created_at: 2.days.ago)
      newest = create_test_run(repository: repository, created_at: 1.day.ago)

      delete repository_run_path(repository, newest)

      expect(repository.reload.latest_test_run.id).to eq(oldest.id)
    end

    # @intent: {"entity": "TestRun", "action": "fall back to empty", "behavior": "deleting the only run leaves latest_test_run nil and the redirected page showing No runs yet", "layer": "request"}
    it "falls back to the no-run empty state when the deleted run was the only one" do
      run = create_test_run(repository: repository)

      delete repository_run_path(repository, run)
      follow_redirect!

      expect(repository.reload.latest_test_run).to be_nil
      expect(response.body).to include("No runs yet")
    end
  end

  # SPGD-1474 (rework): deleting a run changes the stored near-duplicates census's inputs — it
  # can move `repository.latest_test_run` (the run every weight figure is weighed on) and it
  # destroys the per-example observations the figures join through — so the delete requests the
  # census refresh exactly as the ingest path does. These examples hold the scenario the round-2
  # review reproduced: a junk run (the same near-duplicate pair re-reported at inflated
  # durations) becomes the weighed run, the delete removes it, and the stored census must
  # re-weigh on the surviving run — never keep stamping a run that no longer exists, which on a
  # quiet repository would last indefinitely and send a client following `weighed_run_id` to a
  # 404.
  #
  # ⭐ THE PROVIDER IS LEXICAL HERE, on this file family's own rule (see
  # `near_duplicate_clusters_spec.rb`): the suite-wide stub makes two differently-worded texts
  # near-orthogonal however alike they read, so without a stand-in that puts the pair below on a
  # cosine above the floor, the cluster whose weights move would not exist and these assertions
  # would pass over an empty census.
  describe "the stored near-duplicates census it invalidates" do
    include_context "with lexical embeddings"

    let(:expired) { "Checkout rejects an expired card" }
    let(:outright) { "Checkout rejects an expired card outright" }

    # Ingests the checkout pair through the real pipeline — rows and identities come off
    # `Ingest::Payload`, never hand-written, the rule the near-duplicates request spec states —
    # and stores its census through `refresh!`, the compute-and-store unit the census job runs.
    # The fixture side stays OFF `request_refresh!`/the job on purpose: it leaves the job queue
    # empty when the delete fires below, so the delete's OWN enqueue is assertable in isolation.
    def ingest_pair(commit_sha:, duration:)
      payload = Ingest::Payload.new(
        { "commit_sha" => commit_sha, "branch" => "main", "duration_seconds" => 60.0,
          "specs" => [
            unannotated_spec(file_path: "spec/models/checkout_spec.rb", line_number: 3,
                             id: "./spec/models/checkout_spec.rb[1:1]", name: expired,
                             duration: duration),
            unannotated_spec(file_path: "spec/models/checkout_spec.rb", line_number: 9,
                             id: "./spec/models/checkout_spec.rb[2:1]", name: outright,
                             duration: duration * 2)
          ].map(&:deep_stringify_keys) }
      )
      raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

      run = Ingest::RunRecorder.record(repository, payload.test_run_attributes, specs: payload.specs)
      Ingest::IdentityResolver.resolve(run)
      NearDuplicateCensus.refresh!(repository)
      run
    end

    # @intent: {"entity": "TestRun", "action": "re-weigh the census on delete", "behavior": "deleting the weighed run schedules the census job, and draining it re-weighs the stored census onto the surviving run with figures equal to the live computation", "layer": "request"}
    it "re-weighs the stored census onto the surviving run when the weighed run is deleted" do
      good_run = ingest_pair(commit_sha: "feedfacecafe0001", duration: 0.2)
      junk_run = ingest_pair(commit_sha: "feedfacecafe0002", duration: 9.0)
      expect(NearDuplicateCensus.find_by!(repository_id: repository.id).weighed_run_id)
        .to eq(junk_run.id)

      # The delete itself schedules the recompute — the assertion that keeps this behaviour from
      # degrading into "some later ingest happens to heal it".
      expect { delete repository_run_path(repository, junk_run) }
        .to have_enqueued_job(Ingest::NearDuplicateCensusJob).with(repository.id)

      # ...and the job, run the way the worker would run it, moves the stored census onto the
      # surviving run and back onto figures a live computation returns.
      Ingest::NearDuplicateCensusJob.perform_now(repository.id)

      stored = NearDuplicateCensus.find_by!(repository_id: repository.id)
      live = NearDuplicateClusters.for(repository)

      expect(TestRun.exists?(junk_run.id)).to be false
      # A stamp naming a deleted run would send a client following it to the runs API to a 404.
      expect(stored.weighed_run_id).to eq(good_run.id)
      expect(stored.payload).to include(
        "cluster_count" => live.cluster_count,
        "clustered_example_count" => live.clustered_example_count,
        "identity_count" => live.identity_count
      )
      stored_cluster = stored.payload["clusters"].sole
      live_cluster = live.clusters.sole
      expect(stored_cluster["member_count"]).to eq(live_cluster.member_count)
      expect(stored_cluster["total_seconds"]).to eq(live_cluster.total_seconds)
      # ...and the surviving run's weights are the small ones: the junk run's inflated figures
      # are gone from the stored artifact, not just from the live computation.
      expect(stored_cluster["total_seconds"]).to be_within(0.0001).of(0.6)
    end

    # Deleting the ONLY run leaves the census weighed on nothing: `latest_test_run` is nil, the
    # live computation answers with no run, and the stored artifact must carry that shape — the
    # nil weighed run, not a stamp naming a run that no longer exists. The cluster itself
    # SURVIVES (the identities do — nullified, not destroyed — and they still read alike), but
    # every weight figure in it goes unobserved: with no run there is no observation to weigh
    # through, so `example_count` is 0, `total_seconds` is nil and `unobserved_members` states
    # it. The population figures keep reporting the identities too: "no run observes them now",
    # never "no identities exist".
    # @intent: {"entity": "TestRun", "action": "re-weigh census on nothing", "behavior": "deleting the only run re-weighs the stored census onto nothing - nil weighed_run_id, the cluster kept but unobserved - matching the live computation over the same run-less inputs", "layer": "request"}
    it "re-weighs the stored census on nothing when the deleted run was the only one" do
      only_run = ingest_pair(commit_sha: "feedfacecafe0001", duration: 0.2)
      expect(NearDuplicateCensus.find_by!(repository_id: repository.id).weighed_run_id)
        .to eq(only_run.id)

      delete repository_run_path(repository, only_run)
      Ingest::NearDuplicateCensusJob.perform_now(repository.id)

      stored = NearDuplicateCensus.find_by!(repository_id: repository.id)
      live = NearDuplicateClusters.for(repository)

      expect(stored.weighed_run_id).to be_nil
      expect(stored.payload["identity_count"])
        .to eq(live.identity_count).and eq(2)
      # The cluster survives, weighed on nothing: the stored figures are the live computation's
      # over the same run-less inputs — unobserved members, no wall clock, and the stamp of that
      # fact on the cluster.
      stored_cluster = stored.payload["clusters"].sole
      live_cluster = live.clusters.sole
      expect(stored_cluster["member_count"]).to eq(live_cluster.member_count).and eq(2)
      expect(stored_cluster["example_count"]).to eq(live_cluster.example_count).and eq(0)
      expect(stored_cluster["total_seconds"]).to be_nil
      expect(stored_cluster["unobserved_members"]).to be(true)
    end
  end

  describe "who may fire it" do
    # @intent: {"entity": "TestRun", "action": "refuse without permission", "behavior": "a member holding view and keys.manage but not repo.delete gets 403 and the run survives", "layer": "request"}
    it "refuses a member without repo.delete with 403, and the run survives" do
      member = create_user(github_uid: "2002", github_handle: "collaborator")
      create_membership(repository: repository, user: member,
                        permissions: [RepositoryMembership::VIEW, RepositoryMembership::KEYS_MANAGE])
      run = create_test_run(repository: repository)
      sign_in_via_github(uid: "2002", info: { nickname: "collaborator" })

      delete repository_run_path(repository, run)

      expect(response).to have_http_status(:forbidden)
      expect(TestRun.exists?(run.id)).to be true
    end

    # @intent: {"entity": "TestRun", "action": "hide from non-member", "behavior": "a non-member gets 404 rather than 403 so the repository's existence stays hidden, and the run survives", "layer": "request"}
    it "404s a non-member rather than 403ing, so the repository's existence stays hidden" do
      stranger = create_user(github_uid: "3003", github_handle: "stranger")
      run = create_test_run(repository: repository)
      sign_in_via_github(uid: "3003", info: { nickname: "stranger" })

      delete repository_run_path(repository, run)

      expect(response).to have_http_status(:not_found)
      expect(TestRun.exists?(run.id)).to be true
    end
  end

  describe "the run id is scoped through the repository" do
    # @intent: {"entity": "TestRun", "action": "scope the run id", "behavior": "naming another repository's run in this route changes no TestRun count, answers 404, and leaves both runs surviving", "layer": "request"}
    it "cannot delete another repository's run through this route" do
      other_repository = create_repository(user: @user, github_full_name: "acme/other")
      foreign_run = create_test_run(repository: other_repository)
      own_run = create_test_run(repository: repository)

      expect do
        delete repository_run_path(repository, foreign_run)
      end.not_to change(TestRun, :count)

      expect(response).to have_http_status(:not_found)
      expect(TestRun.exists?(foreign_run.id)).to be true
      expect(TestRun.exists?(own_run.id)).to be true
    end
  end

  describe "the control" do
    # @intent: {"entity": "TestRun", "action": "render delete control", "behavior": "a viewer with repo_delete sees a Delete button whose dialog names removing the run's shards and per-example observations and that it cannot be undone", "layer": "request"}
    it "renders a Delete button with a dialog naming the consequence, for a viewer with repo_delete" do
      create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6")

      get repository_path(repository)

      expect(response.body).to include("Delete")
      expect(response.body).to include("its shards and its per-example observations")
      expect(response.body).to include("cannot be undone")
    end

    # @intent: {"entity": "TestRun", "action": "omit delete control", "behavior": "a viewer lacking repo_delete gets neither the Delete button nor the cannot-be-undone dialog text anywhere on the page", "layer": "request"}
    it "renders no Delete control at all for a viewer lacking repo_delete" do
      member = create_user(github_uid: "2002", github_handle: "collaborator")
      create_membership(repository: repository, user: member)
      create_test_run(repository: repository)
      sign_in_via_github(uid: "2002", info: { nickname: "collaborator" })

      get repository_path(repository)

      # The whole control, button and dialog sentence, is absent — not disabled, not present with
      # a different label. An affordance that can only ever produce a 403 is not rendered.
      expect(response.body).not_to include(">Delete<")
      expect(response.body).not_to include("cannot be undone")
    end
  end
end
