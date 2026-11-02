# frozen_string_literal: true

require "rails_helper"

# SPGD-2014: deleting ONE run over the API — the machine-facing half of the web surface's run
# delete (`repository_run_deletion_spec.rb`), on the same `:repo_delete` gate, the same
# repository-scoped lookup, and the same cascade the web action fires. The run id the route
# consumes is the one `latest_run.id` and every `history[]` row now carry, so an agent can read
# the overview and act on it without a browser.
#
# What these examples hold down is that the delete is surgical, gated, and honest:
#   - exactly the named row and its per-run children go; durable rows survive nullified;
#   - a member without `repo.delete` gets the 403 every other `:repo_delete` gate gives;
#   - a non-member and a foreign/unknown run id both learn nothing beyond 404 — and the two 404s
#     are indistinguishable, so an id enumeration learns nothing;
#   - the near-duplicates census refresh is enqueued, exactly as the web action enqueues it
#     (SPGD-1474): deleting a run can move `latest_test_run` and destroys the observations the
#     stored weights join through;
#   - the `sga_` agent credential deletes on the same terms, bounded by its own grant, per the
#     SPGD-973 reading the repository-delete verb already follows.
RSpec.describe "API v1 — deleting a repository run", type: :request do
  let(:owner) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: owner, github_full_name: "acme/billing-service") }
  let(:owner_key) { create_user_api_key(user: owner) }

  # A member with only `view` — the 403 half of the fork — and a stranger — the 404 half.
  let(:member) { create_user(github_uid: "9999", github_handle: "hubot") }
  let(:member_key) { create_user_api_key(user: member) }
  let(:stranger) { create_user(github_uid: "7777", github_handle: "locutus") }
  let(:stranger_key) { create_user_api_key(user: stranger) }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  def delete_path(run, repo = repository) = "/api/v1/repositories/#{repo.id}/runs/#{run.id}"

  describe "DELETE /api/v1/repositories/:repository_id/runs/:id" do
    # @intent: { entity: "repository run", action: "delete one run", behavior: "the owner user key deletes the named run, answers 204 with no body, and exactly that row is gone", layer: "request" }
    it "deletes exactly the named run for the owner and answers 204" do
      run = create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6")
      other_run = create_test_run(repository: repository, commit_sha: "0f0f0f0f0f0f")

      expect {
        delete delete_path(run), headers: bearer(owner_key.raw_token)
      }.to change(TestRun, :count).by(-1)

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_blank
      expect(TestRun.exists?(run.id)).to be(false)
      expect(TestRun.exists?(other_run.id)).to be(true)
    end

    # @intent: { entity: "repository run", action: "delete for a delete member", behavior: "a member granted repo.delete deletes the run, the same permission fork the web run delete carries", layer: "request" }
    it "deletes the run for a member granted repo.delete" do
      run = create_test_run(repository: repository)

      create_membership(repository: repository, user: member, permissions: %w[view repo.delete])

      expect {
        delete delete_path(run), headers: bearer(member_key.raw_token)
      }.to change(TestRun, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    # @intent: { entity: "repository run", action: "refuse a view member", behavior: "a member holding only view is refused 403 with the api error JSON and no run is deleted", layer: "request" }
    it "answers 403 JSON for a member with only view" do
      run = create_test_run(repository: repository)
      create_membership(repository: repository, user: member, permissions: %w[view])

      expect {
        delete delete_path(run), headers: bearer(member_key.raw_token)
      }.not_to change(TestRun, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
      expect(response.media_type).to eq("application/json")
    end

    # @intent: { entity: "repository run", action: "hide from a stranger", behavior: "a non-member is told 404 in JSON so the repository existence stays hidden rather than merely its contents", layer: "request" }
    it "answers 404 JSON for a non-member, hiding the repository" do
      run = create_test_run(repository: repository)

      expect {
        delete delete_path(run), headers: bearer(stranger_key.raw_token)
      }.not_to change(TestRun, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("error" => "not_found")
      expect(response.media_type).to eq("application/json")
    end

    # @intent: { entity: "repository run", action: "answer for an unknown id", behavior: "a run id matching nothing at all answers 404 with the crafted sentence", layer: "request" }
    it "answers 404 for a run id matching nothing" do
      create_test_run(repository: repository)

      delete "/api/v1/repositories/#{repository.id}/runs/999999",
             headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq(
        "error" => "not_found",
        "message" => "No run with that id belongs to this repository."
      )
    end

    # The two 404s are deliberately indistinguishable, and this is the example that pins it: a
    # run id belonging to ANOTHER repository answers the same crafted sentence an unknown id
    # answers, so a caller holding ids it should not see cannot probe their existence here.
    # The lookup is `repository.test_runs.find_by`, which is the whole scoping.
    # @intent: { entity: "repository run", action: "hide a foreign run", behavior: "a run id belonging to another repository answers the same 404 sentence an unknown id answers, so the two refusals are indistinguishable", layer: "request" }
    it "answers the same 404 for a run id belonging to another repository" do
      other_repository = create_repository(user: owner, github_full_name: "acme/other-service")
      foreign_run = create_test_run(repository: other_repository, commit_sha: "deadbeeffeef")

      delete delete_path(foreign_run), headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq(
        "error" => "not_found",
        "message" => "No run with that id belongs to this repository."
      )
      expect(TestRun.exists?(foreign_run.id)).to be(true)
    end

    # @intent: { entity: "repository run", action: "nullify durable rows", behavior: "the api delete destroys the shard and the observation but leaves the spec intent and the last-seen identity alive with their run foreign keys nulled, the same cascade the web action fires", layer: "request" }
    it "deletes shards and observations but nullifies intents and last-seen identities" do
      run = create_test_run(repository: repository, ci_run_id: "ci-1")
      shard = run.test_run_shards.create!(shard_id: "1", total_specs_count: 5)
      observation = run.spec_observations.create!(
        repository: repository, file_path: "spec/models/invoice_spec.rb", line_number: 12,
        status: "annotated"
      ).tap { |o| o.update!(test_run_shard: shard) }
      intent = create_spec_intent(repository: repository, test_run: run)
      identity = create_spec_identity(repository: repository)
      identity.update!(last_seen_test_run: run)

      delete delete_path(run), headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:no_content)
      expect(TestRunShard.exists?(shard.id)).to be(false)
      expect(SpecObservation.exists?(observation.id)).to be(false)
      # Durable rows survive, nullified — the cascade `TestRun` declares is the whole argument,
      # mirrored from the web action's spec so neither surface can grow a second behaviour.
      expect(SpecIntent.exists?(intent.id)).to be(true)
      expect(intent.reload.test_run_id).to be_nil
      expect(SpecIdentity.exists?(identity.id)).to be(true)
      expect(identity.reload.last_seen_test_run_id).to be_nil
    end

    # SPGD-1474, mirrored from the web action: deleting a run can move `latest_test_run` (the run
    # every stored census weight is weighed on) and destroys the observations those weights join
    # through, so the delete requests the census refresh exactly as the ingest path does. The
    # assertion is the enqueue itself — the one that keeps this from degrading into "some later
    # ingest happens to heal it".
    # @intent: { entity: "repository run", action: "re-weigh the census on delete", behavior: "the api delete enqueues the near-duplicate census job for the repository, the same refresh the web action requests", layer: "request" }
    it "enqueues the near-duplicates census refresh for the repository" do
      run = create_test_run(repository: repository)

      expect {
        delete delete_path(run), headers: bearer(owner_key.raw_token)
      }.to have_enqueued_job(Ingest::NearDuplicateCensusJob).with(repository.id)

      expect(response).to have_http_status(:no_content)
    end

    # The overview side of the round trip: the id an agent reads off `history[]` is the id this
    # route deletes, and after the delete the overview no longer lists the run — the acceptance
    # criterion the ticket states, held end to end rather than asserted on either half alone.
    # @intent: { entity: "repository run", action: "read then delete", behavior: "an id read off the overview history row deletes exactly that run and the next overview no longer lists it", layer: "request" }
    it "deletes the run an overview history row names, and the overview stops listing it" do
      oldest = create_test_run(repository: repository, commit_sha: "feedfacecafe0001",
                               created_at: 2.days.ago)
      newest = create_test_run(repository: repository, commit_sha: "feedfacecafe0002",
                               created_at: 1.day.ago)

      get "/api/v1/repositories/#{repository.id}", headers: bearer(owner_key.raw_token)
      served = response.parsed_body
      expect(served.dig("latest_run", "id")).to eq(newest.id)
      served_ids = served["history"].map { |row| row["id"] }
      expect(served_ids).to contain_exactly(oldest.id, newest.id)
      # The junk-run story this route exists for: the NEWEST run (history is newest-first, and
      # `latest_run` is history[0] on an unfiltered window) is the one an agent deletes.
      junk_id = served_ids.first
      expect(junk_id).to eq(newest.id)

      delete "/api/v1/repositories/#{repository.id}/runs/#{junk_id}",
             headers: bearer(owner_key.raw_token)
      expect(response).to have_http_status(:no_content)

      get "/api/v1/repositories/#{repository.id}", headers: bearer(owner_key.raw_token)
      after = response.parsed_body
      expect(after["history"].map { |row| row["id"] }).to eq([oldest.id])
      expect(after.dig("latest_run", "id")).to eq(oldest.id)
    end
  end

  describe "DELETE /api/v1/repositories/:repository_id/runs/:id over the agent credential" do
    # SPGD-973's reading, mirrored from the repository-delete verb: the `:repo_delete` gate is the
    # whole answer for the agent credential — no person in the request, no person-shaped rule.
    # @intent: { entity: "repository run", action: "delete for the agent key", behavior: "an agent key holding repo.delete deletes a run of a repository in its set", layer: "request" }
    it "deletes a run for an agent key holding repo.delete on a repository in its set" do
      run = create_test_run(repository: repository)
      key = create_agent_api_key(user: owner, repositories: [repository],
                                 permissions: ["repo.delete"])

      expect {
        delete delete_path(run), headers: bearer(key.raw_token)
      }.to change(TestRun, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    # @intent: { entity: "repository run", action: "refuse an unpermitted agent delete", behavior: "an in-set repository run asked for deletion by a key without repo.delete answers 403 and nothing is deleted", layer: "request" }
    it "answers 403 without the repo.delete permission" do
      run = create_test_run(repository: repository)
      key = create_agent_api_key(user: owner, repositories: [repository], permissions: [])

      expect {
        delete delete_path(run), headers: bearer(key.raw_token)
      }.not_to change(TestRun, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # @intent: { entity: "repository run", action: "hide the ungranted delete", behavior: "a run of a repository outside the key's set answers 404, even with repo.delete held", layer: "request" }
    it "answers 404 for a run of a repository outside the set, even holding repo.delete" do
      other_repository = create_repository(user: owner, github_full_name: "acme/elsewhere")
      run = create_test_run(repository: other_repository)
      key = create_agent_api_key(user: owner, repositories: [repository],
                                 permissions: ["repo.delete"])

      delete delete_path(run), headers: bearer(key.raw_token)

      expect(response).to have_http_status(:not_found)
      expect(TestRun.exists?(run.id)).to be(true)
    end

    # @intent: { entity: "repository run", action: "refuse the repository key", behavior: "an sgk_ repository key is a different credential kind and answers 401, the seam direction every user-surface endpoint carries", layer: "request" }
    it "answers 401 to an sgk_ repository key" do
      run = create_test_run(repository: repository)

      delete delete_path(run), headers: bearer(repository.api_keys.create!.raw_token)

      expect(response).to have_http_status(:unauthorized)
      expect(TestRun.exists?(run.id)).to be(true)
    end
  end
end
