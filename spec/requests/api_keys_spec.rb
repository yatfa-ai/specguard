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
    # @intent: {"entity": "POST /repositories/:id/api_keys", "action": "mint as owner", "behavior": "posting api_key name CI creates one key attributed to the owner through created_by_user and redirects to the repository page anchored at revealed-key", "layer": "request"}
    it "creates the key for the owner, with the minter attributed" do
      expect {
        post repository_api_keys_path(repository), params: { api_key: { name: "CI" } }
      }.to change(ApiKey, :count).by(1)

      expect(repository.api_keys.last.created_by_user).to eq(owner)
      expect(response).to redirect_to(repository_path(repository, anchor: "revealed-key"))
    end

    # @intent: {"entity": "POST /repositories/:id/api_keys", "action": "refuse view-only member", "behavior": "a member with only view gets 403 and the ApiKey count is unchanged", "layer": "request"}
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
    # @intent: {"entity": "POST /repositories/:id/api_keys", "action": "hide from non-member", "behavior": "a non-member gets 404 rather than 403, so the repository's existence stays hidden, and no key is created", "layer": "request"}
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

    # @intent: {"entity": "DELETE /repositories/:id/api_keys/:key_id", "action": "revoke as owner", "behavior": "the owner's delete removes the key and redirects to the repository page", "layer": "request"}
    it "revokes the key for the owner" do
      expect {
        delete repository_api_key_path(repository, ci_key)
      }.to change(ApiKey, :count).by(-1)

      expect(response).to redirect_to(repository_path(repository))
    end

    # @intent: {"entity": "DELETE /repositories/:id/api_keys/:key_id", "action": "revoke with keys.manage", "behavior": "a member holding view and keys.manage removes the key, the count dropping by one", "layer": "request"}
    it "revokes the key for a member granted keys.manage" do
      member = create_user(github_uid: "9999", github_handle: "hubot")
      create_membership(repository: repository, user: member, permissions: %w[view keys.manage])
      sign_in_via_github(uid: "9999", info: { nickname: "hubot" })

      expect {
        delete repository_api_key_path(repository, ci_key)
      }.to change(ApiKey, :count).by(-1)
    end

    # @intent: {"entity": "DELETE /repositories/:id/api_keys/:key_id", "action": "refuse view-only member", "behavior": "a member with only view gets 403 and the key survives", "layer": "request"}
    it "answers 403 for a member with only view" do
      member = create_user(github_uid: "9999", github_handle: "hubot")
      create_membership(repository: repository, user: member, permissions: %w[view])
      sign_in_via_github(uid: "9999", info: { nickname: "hubot" })

      expect {
        delete repository_api_key_path(repository, ci_key)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # @intent: {"entity": "DELETE /repositories/:id/api_keys/:key_id", "action": "hide from non-member", "behavior": "a non-member gets 404 with the key surviving, so the repository's existence stays hidden", "layer": "request"}
    it "answers 404 for a non-member, hiding the repository" do
      create_user(github_uid: "7777", github_handle: "locutus")
      sign_in_via_github(uid: "7777", info: { nickname: "locutus" })

      expect {
        delete repository_api_key_path(repository, ci_key)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  # SPGD-924: the mint's flash keys are this surface's own — the mirror of the user-surface
  # example in spec/requests/account_api_keys_spec.rb. A flash is delivered to whatever request
  # arrives next, and while the two credential surfaces shared one namespace, an intervening
  # `accounts#show` read a freshly minted `sgk_` token off it and rendered it in a panel
  # labelling it as the person's own key. The mint below deliberately does NOT follow its
  # redirect, so the flash is armed across the intervening visit — the state a browser is in
  # between the POST's 302 and its landing page.
  #
  # As on the user surface: distinct key names confine the mint to its own reader, and no naming
  # could make it SURVIVE an intervening request — Rails discards every session-borne flash entry
  # at the end of each request that touches the flash, read or not. After the account visit the
  # token renders nowhere; the recovery is this surface's own Regenerate (or revoke and re-mint),
  # unchanged and out of scope here.
  describe "an intervening request on the other credential surface" do
    # @intent: {"entity": "POST /repositories/:id/api_keys", "action": "confine reveal to own surface", "behavior": "an account page loaded between the mint POST and the repository landing renders no sgk_ token and no reveal panel, and the repository page afterwards shows none either.", "layer": "request"}
    it "renders the fresh token in no account panel" do
      post repository_api_keys_path(repository), params: { api_key: { name: "CI" } }
      expect(response).to redirect_to(repository_path(repository, anchor: "revealed-key"))

      # The mis-route itself: this page renders its reveal panel whenever the flash it reads
      # carries anything, so before the key split BOTH assertions failed here.
      get account_path
      expect(response.body).not_to match(/sgk_[A-Za-z0-9_-]{20,}/)
      expect(response.body).not_to include("Your new API key")

      # Consumed by the intervening visit, read or not — the landing page shows nothing either.
      get repository_path(repository)
      expect(response.body).not_to match(/sgk_[A-Za-z0-9_-]{20,}/)
    end
  end
end
