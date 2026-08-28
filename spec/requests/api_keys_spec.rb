# frozen_string_literal: true

require "rails_helper"

# SPGD-754: the web-side authorization fork for MINTING and REVOKING a repository's `sgk_` keys —
# the two actions the concern extraction mirrors onto the API tree, which had no request spec of
# their own before this file. The api-key fork was previously locked only through `#regenerate`
# (spec/requests/repository_api_key_regeneration_spec.rb), which is precisely the action the API
# slice does NOT port — so the extraction was least protected on exactly the two actions it
# mirrors. This file is the measurement that "the web side is unchanged" rests on: no assertion in
# the sibling fork specs is edited, and these examples pin the fork for the ported pair.
RSpec.describe "Repository API keys (web)", type: :request do
  let!(:owner) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: owner, github_full_name: "acme/billing-service") }

  # EAGER (`let!`) so the row exists before the sign-in below: `sign_in_via_github` finds-or-creates
  # by uid, so a lazy `owner` would run AFTER the session was created and collide on the uid.

  before { sign_in_via_github(uid: "1001") }

  describe "minting (POST /repositories/:id/api_keys)" do
    it "creates the key for the owner, with the minter attributed" do
      expect {
        post repository_api_keys_path(repository), params: { api_key: { name: "CI" } }
      }.to change(ApiKey, :count).by(1)

      expect(repository.api_keys.last.created_by_user).to eq(owner)
      expect(response).to redirect_to(repository_path(repository, anchor: "revealed-key"))
    end

    it "answers 403 for a member with only view" do
      member = create_user(github_uid: "9999", github_handle: "hubot")
      create_membership(repository: repository, user: member, permissions: %w[view])
      sign_in_via_github(uid: "9999", info: { nickname: "hubot" })

      expect {
        post repository_api_keys_path(repository)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # The hidden-existence half of the fork, which the 403 example cannot see: a NON-member is
    # answered 404, not 403, so the repository's existence stays hidden from them.
    it "answers 404 for a non-member, hiding the repository" do
      create_user(github_uid: "7777", github_handle: "locutus")
      sign_in_via_github(uid: "7777", info: { nickname: "locutus" })

      expect {
        post repository_api_keys_path(repository)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "revoking (DELETE /repositories/:id/api_keys/:key_id)" do
    let!(:ci_key) { repository.api_keys.create!(name: "CI") }

    it "revokes the key for the owner" do
      expect {
        delete repository_api_key_path(repository, ci_key)
      }.to change(ApiKey, :count).by(-1)

      expect(response).to redirect_to(repository_path(repository))
    end

    it "revokes the key for a member granted keys.manage" do
      member = create_user(github_uid: "9999", github_handle: "hubot")
      create_membership(repository: repository, user: member, permissions: %w[view keys.manage])
      sign_in_via_github(uid: "9999", info: { nickname: "hubot" })

      expect {
        delete repository_api_key_path(repository, ci_key)
      }.to change(ApiKey, :count).by(-1)
    end

    it "answers 403 for a member with only view" do
      member = create_user(github_uid: "9999", github_handle: "hubot")
      create_membership(repository: repository, user: member, permissions: %w[view])
      sign_in_via_github(uid: "9999", info: { nickname: "hubot" })

      expect {
        delete repository_api_key_path(repository, ci_key)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "answers 404 for a non-member, hiding the repository" do
      create_user(github_uid: "7777", github_handle: "locutus")
      sign_in_via_github(uid: "7777", info: { nickname: "locutus" })

      expect {
        delete repository_api_key_path(repository, ci_key)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
