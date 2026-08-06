# frozen_string_literal: true

require "rails_helper"

# Sharing slice 2b, the owner side: `/repositories/:repository_id/members` — list who has access,
# and take it away. This is the first production call site `members.manage` has ever had, so these
# examples are also the first proof that the permission decides anything at all.
#
# `sign_in_via_github(uid: ...)` drives the real OAuth callback, so calling it a second time
# *switches* the signed-in identity.
RSpec.describe "Repository members", type: :request do
  let(:owner) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: owner, github_full_name: "acme/billing-service") }
  let(:colleague) { create_user(github_uid: "9999", github_handle: "hubot") }

  describe "the owner" do
    before do
      repository
      sign_in_via_github
    end

    it "sees every member with their permission set" do
      create_membership(repository: repository, user: colleague, permissions: %w[view keys.manage])

      get repository_members_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("hubot")
      expect(response.body).to include("keys.manage")
    end

    # RepositoryMembership#user_is_not_the_owner makes an owner row impossible, so "the owner always
    # retains all permissions" holds structurally. This asserts the consequence rather than adding a
    # filter that would mask the invariant regressing — the same reasoning as the deliberate absence
    # of `.distinct` in RepositoriesController#index.
    it "does not see themselves in the list" do
      create_membership(repository: repository, user: colleague)

      get repository_members_path(repository)

      expect(response.body).to include("hubot")
      # The owner's own handle is in the topbar — they are signed in — so this has to be scoped to
      # the table: exactly one revoke control, and none of them aimed at the owner.
      expect(response.body.scan(%r{/repositories/#{repository.id}/members/\d+}).size).to eq(1)
      expect(response.body).not_to include("Revoke octocat")
    end

    # A blank table says "loading failed" as readily as "nobody has access"; and the reason the page
    # offers no Add control is worth stating on the page rather than only in the commit.
    it "sees an empty state naming that add-by-handle is not available yet, not a blank table" do
      get repository_members_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No one else has access")
      expect(response.body).to include("not available yet")
    end

    it "can revoke a member's access" do
      membership = create_membership(repository: repository, user: colleague)

      expect {
        delete repository_member_path(repository, membership)
      }.to change(RepositoryMembership, :count).by(-1)

      expect(response).to redirect_to(repository_members_path(repository))
    end
  end

  # The permission is not owner-only: the roadmap grants it "add/remove collaborators", so a
  # non-owner holder is legitimate and gets the same page.
  describe "a member holding 'members.manage'" do
    let(:third_party) { create_user(github_uid: "8888", github_handle: "dependabot") }

    before do
      create_membership(repository: repository, user: colleague, permissions: %w[view members.manage])
      create_membership(repository: repository, user: third_party, permissions: %w[view])
      sign_in_via_github(uid: "9999")
    end

    it "can open the members page" do
      get repository_members_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dependabot")
    end

    it "can revoke another member, whose access really is gone afterwards" do
      membership = RepositoryMembership.find_by!(user: third_party, repository: repository)

      expect {
        delete repository_member_path(repository, membership)
      }.to change(RepositoryMembership, :count).by(-1)

      # The revoked user is now a stranger to the repository: 404 on its own URL, absent from the
      # index. Anything less means the row went away but the access did not.
      sign_in_via_github(uid: "8888")

      get repository_path(repository)
      expect(response).to have_http_status(:not_found)

      get repositories_path
      expect(response.body).not_to include("acme/billing-service")
    end

    # Their own access is theirs to give up, and nothing guards it. They are then a stranger to the
    # members page, so the redirect has to go somewhere that still exists.
    it "can revoke themselves, and is redirected off the page they just lost" do
      own_membership = RepositoryMembership.find_by!(user: colleague, repository: repository)

      expect {
        delete repository_member_path(repository, own_membership)
      }.to change(RepositoryMembership, :count).by(-1)

      expect(response).to redirect_to(repositories_path)

      get repository_members_path(repository)
      expect(response).to have_http_status(:not_found)
    end
  end

  # The table names people — handles and avatars. That is the same category as the credential
  # metadata repositories#show already gates: the whole surface is refused, not just the button.
  describe "a member with only 'view'" do
    let!(:membership) { create_membership(repository: repository, user: colleague, permissions: %w[view]) }

    before { sign_in_via_github(uid: "9999") }

    it "gets 403 on the members page" do
      get repository_members_path(repository)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot revoke anyone" do
      expect {
        delete repository_member_path(repository, membership)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  # 404 rather than 403: the repository's existence stays hidden from a non-member, exactly as it
  # does on every other repository action.
  describe "a signed-in user with no membership" do
    let!(:membership) { create_membership(repository: repository, user: colleague) }

    before { sign_in_via_github(uid: "7777") }

    it "gets 404 on both actions, and revokes nothing" do
      get repository_members_path(repository)
      expect(response).to have_http_status(:not_found)

      expect {
        delete repository_member_path(repository, membership)
      }.not_to change(RepositoryMembership, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  # The IDOR this slice exists to not ship. On a nested member route `params[:id]` is a *membership*
  # id while `current_repository` authorized against `params[:repository_id]`, so a global
  # `RepositoryMembership.find` would authorize against repository A and then delete a row belonging
  # to repository B. The lookup must be scoped through the repository, as ApiKeysController#destroy
  # already scopes through `repository.api_keys`.
  describe "revoking across repositories" do
    it "refuses a membership id that belongs to a different repository" do
      other_owner = create_user(github_uid: "2002", github_handle: "other-owner")
      other_repository = create_repository(user: other_owner, github_full_name: "acme/payments-service")
      victim = create_membership(repository: other_repository,
                                 user: create_user(github_uid: "3003", github_handle: "victim"))

      create_membership(repository: repository, user: colleague, permissions: %w[view members.manage])
      sign_in_via_github(uid: "9999")

      expect {
        delete repository_member_path(repository, victim)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:not_found)
      expect(RepositoryMembership.exists?(victim.id)).to be(true)
    end
  end

  describe "a signed-out visitor" do
    it "is sent to sign in rather than shown the list" do
      create_membership(repository: repository, user: colleague)

      get repository_members_path(repository)

      expect(response).to redirect_to(root_path)
    end
  end
end
