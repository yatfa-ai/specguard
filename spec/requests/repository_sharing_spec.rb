# frozen_string_literal: true

require "rails_helper"

# Slice 1 of repository sharing: authorization only. There is no members-management UI yet, so
# memberships are created directly and exercised over HTTP from the member's own session.
#
# `sign_in_via_github(uid: ...)` drives the real OAuth callback, so calling it a second time
# *switches* the signed-in identity — that is what makes these member-perspective specs, rather
# than the owner-perspective ones the existing suite already has.
RSpec.describe "Repository sharing", type: :request do
  let(:owner) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: owner, github_full_name: "acme/billing-service") }

  # Signs in a second GitHub identity and shares `repository` with them.
  def sign_in_as_member(permissions)
    create_membership(repository: repository, user: sign_in_via_github(uid: "9999"), permissions: permissions)
  end

  describe "a member with only 'view'" do
    before { sign_in_as_member(%w[view]) }

    it "can open the shared repository" do
      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/billing-service")
    end

    # 403 rather than 404: they can already see the repository, so pretending it is missing lies.
    it "cannot mint an API key" do
      expect {
        post repository_api_keys_path(repository)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot revoke an existing API key" do
      api_key = repository.api_keys.create!(name: "CI")

      expect {
        delete repository_api_key_path(repository, api_key)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # Rename is owner-only for v1: `github_full_name` is the repository's identity and the global
    # unique key, and no membership permission covers it.
    it "cannot rename the repository" do
      patch repository_path(repository), params: { repository: { github_full_name: "acme/stolen" } }

      expect(response).to have_http_status(:forbidden)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")

      get edit_repository_path(repository)
      expect(response).to have_http_status(:forbidden)
    end

    it "cannot remove the repository" do
      expect {
        delete repository_path(repository)
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # Slice 2 (members management UI + shared-repo index) is where this changes. Until then a
    # shared repository is reachable by URL but is not listed for the member.
    it "does not yet see the shared repository in their index" do
      get repositories_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("acme/billing-service")
    end
  end

  describe "a member with 'keys.manage'" do
    before { sign_in_as_member(%w[view keys.manage]) }

    it "can create and revoke an API key on the shared repository" do
      expect {
        post repository_api_keys_path(repository)
      }.to change { repository.api_keys.count }.by(1)

      follow_redirect!
      expect(response.body).to match(/sgk_[A-Za-z0-9_-]{20,}/)

      expect {
        delete repository_api_key_path(repository, repository.api_keys.last)
      }.to change { repository.api_keys.count }.by(-1)
    end
  end

  describe "a member with 'repo.delete'" do
    before { sign_in_as_member(%w[view repo.delete]) }

    it "can remove the shared repository" do
      expect {
        delete repository_path(repository)
      }.to change(Repository, :count).by(-1)

      expect(response).to redirect_to(repositories_path)
    end
  end

  # Granting only `keys.manage` and not `view` is what a members UI checkbox grid will produce by
  # accident; the policy must not lock the member out of the page the keys live on.
  describe "a member granted a permission without an explicit 'view'" do
    before { sign_in_as_member(%w[keys.manage]) }

    it "can still open the repository" do
      get repository_path(repository)

      expect(response).to have_http_status(:ok)
    end
  end

  # The examples above prove every control *rejects* a member who lacks its permission. These prove
  # the control is never offered in the first place — a "Remove" button that asks a member to
  # confirm destroying the repository and all of its data, then dead-ends on a 403, is worse than
  # no button at all.
  describe "which controls repositories#show renders" do
    let!(:api_key) { repository.api_keys.create!(name: "CI") }

    # Each control, identified by a marker that only appears when it actually rendered.
    def rendered_controls
      {
        rename: response.body.include?(edit_repository_path(repository)),
        remove: response.body.include?("and all of its data?"),
        new_key: response.body.include?("New API key"),
        revoke: response.body.include?(repository_api_key_path(repository, api_key)),
        key_inventory: response.body.include?(api_key.token_hint)
      }
    end

    # The positive control, and it is load-bearing: without it every `false` below would keep
    # passing if a label or a route were renamed out from under the markers.
    it "renders all of them for the owner" do
      repository
      sign_in_via_github

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(rendered_controls.values).to all(be(true))
    end

    it "renders none of them for a member with only 'view'" do
      sign_in_as_member(%w[view])

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/billing-service")
      expect(rendered_controls.values).to all(be(false))
    end

    # The whole API keys panel is gated, not just its two buttons: key names, token hints and
    # last-used timestamps are credential metadata, and nothing a member without `keys.manage` can
    # act on. The endpoint documentation and connection stat stay — see the comment in show.html.erb.
    it "renders the key controls, and only those, for a member with 'keys.manage'" do
      sign_in_as_member(%w[view keys.manage])

      get repository_path(repository)

      expect(rendered_controls).to eq(
        rename: false, remove: false, new_key: true, revoke: true, key_inventory: true
      )
    end

    it "renders remove, and only that, for a member with 'repo.delete'" do
      sign_in_as_member(%w[view repo.delete])

      get repository_path(repository)

      expect(rendered_controls).to eq(
        rename: false, remove: true, new_key: false, revoke: false, key_inventory: false
      )
    end
  end

  describe "a signed-in user with no membership" do
    before do
      repository
      sign_in_via_github(uid: "8888")
    end

    # Existence stays hidden — the same shape as before sharing existed, when `current_repository`
    # scoped its `.find` to the signed-in user's own repositories.
    it "gets 404, not 403, on every repository action" do
      get repository_path(repository)
      expect(response).to have_http_status(:not_found)

      get edit_repository_path(repository)
      expect(response).to have_http_status(:not_found)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/stolen" } }
      expect(response).to have_http_status(:not_found)

      expect { post repository_api_keys_path(repository) }.not_to change(ApiKey, :count)
      expect(response).to have_http_status(:not_found)

      expect { delete repository_path(repository) }.not_to change(Repository, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the owner" do
    # `repository` first: it creates the owner with uid 1001, which is the identity
    # `sign_in_via_github` then resolves to (User.from_github_omniauth upserts on the uid).
    before do
      repository
      sign_in_via_github
    end

    it "still does everything with no membership row of their own" do
      expect(RepositoryMembership.where(user: owner)).to be_empty

      get repository_path(repository)
      expect(response).to have_http_status(:ok)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/renamed" } }
      expect(repository.reload.github_full_name).to eq("acme/renamed")

      expect { post repository_api_keys_path(repository) }.to change(ApiKey, :count).by(1)
      expect { delete repository_path(repository) }.to change(Repository, :count).by(-1)
    end

    it "is unaffected by another user holding a membership" do
      create_membership(repository: repository, user: create_user(github_uid: "9999", github_handle: "someone-else"),
                        permissions: RepositoryMembership::PERMISSIONS)

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
    end
  end
end
