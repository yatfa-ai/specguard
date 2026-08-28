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
    it "removes exactly that run and redirects to the repository page, naming sha and branch" do
      run = create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6", branch: "main")

      delete repository_run_path(repository, run)

      expect(response).to redirect_to(repository_path(repository))
      expect { run.reload }.to raise_error(ActiveRecord::RecordNotFound)
      follow_redirect!
      expect(response.body).to include("Deleted run a1b2c3d (main)")
    end

    it "says 'branch not reported' rather than a blank when the run reported no branch" do
      run = create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6", branch: nil)

      delete repository_run_path(repository, run)
      follow_redirect!

      expect(response.body).to include("Deleted run a1b2c3d (branch not reported)")
    end

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

    it "advances latest_test_run to the next-newest run by the shared ordering, tie-break included" do
      oldest = create_test_run(repository: repository, created_at: 2.days.ago)
      newest = create_test_run(repository: repository, created_at: 1.day.ago)

      delete repository_run_path(repository, newest)

      expect(repository.reload.latest_test_run.id).to eq(oldest.id)
    end

    it "falls back to the no-run empty state when the deleted run was the only one" do
      run = create_test_run(repository: repository)

      delete repository_run_path(repository, run)
      follow_redirect!

      expect(repository.reload.latest_test_run).to be_nil
      expect(response.body).to include("No runs yet")
    end
  end

  describe "who may fire it" do
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
    it "renders a Delete button with a dialog naming the consequence, for a viewer with repo_delete" do
      create_test_run(repository: repository, commit_sha: "a1b2c3d4e5f6")

      get repository_path(repository)

      expect(response.body).to include("Delete")
      expect(response.body).to include("its shards and its per-example observations")
      expect(response.body).to include("cannot be undone")
    end

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
