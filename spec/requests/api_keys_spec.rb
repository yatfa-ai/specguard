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

    # SPGD-1898: the name and the form root are read shape-safely. A scalar `api_key=x` root used
    # to raise a TypeError (HTML 500) and a Hash or Array `name` was stored as its Ruby inspect
    # string; both now take the blank-name answer, the default name.
    # @intent: {"entity": "POST /repositories/:id/api_keys", "action": "mint with a scalar api_key root", "behavior": "posting api_key as a bare scalar mints one key with the default name and redirects to the repository page anchored at revealed-key instead of raising a 500", "layer": "request"}
    it "mints a default-named key when the api_key root is a scalar" do
      expect {
        post repository_api_keys_path(repository), params: { api_key: "x" }
      }.to change(ApiKey, :count).by(1)

      expect(repository.api_keys.last.name).to eq(ApiKey::DEFAULT_NAME)
      expect(response).to redirect_to(repository_path(repository, anchor: "revealed-key"))
    end

    # @intent: {"entity": "POST /repositories/:id/api_keys", "action": "mint with a non-String name", "behavior": "posting a Hash or an Array as the api_key name mints one key with the default name rather than storing the value's Ruby inspect string", "layer": "request"}
    it "mints a default-named key when the name is a Hash or an Array" do
      [{ a: "b" }, ["b"]].each do |shape|
        expect {
          post repository_api_keys_path(repository), params: { api_key: { name: shape } }
        }.to change(ApiKey, :count).by(1)

        expect(repository.api_keys.last.name).to eq(ApiKey::DEFAULT_NAME)
        expect(response).to redirect_to(repository_path(repository, anchor: "revealed-key"))
      end
    end

    # SPGD-1476: a NUL in the name is refused by the model's format validator, so the mint
    # redirects back with an alert and writes nothing instead of raising at INSERT (Postgres
    # cannot store a NUL). The double-quoted literal is load-bearing — the single-quoted
    # 'CI\u0000x' is six printable characters and must still mint.
    # @intent: {"entity": "POST /repositories/:id/api_keys", "action": "refuse a NUL in the name", "behavior": "minting a key whose name carries a NUL redirects back to the repository page with an alert, writes no key, and reveals no token", "layer": "request"}
    it "redirects with an alert and writes nothing when the name carries a NUL" do
      expect {
        post repository_api_keys_path(repository), params: { api_key: { name: "CI\u0000x" } }
      }.not_to change(ApiKey, :count)

      expect(response).to redirect_to(repository_path(repository))
      expect(flash[:alert]).to be_present
      expect(flash[:revealed_api_key]).to be_nil
    end

    # SPGD-1878: a name past NAME_MAX_LENGTH is refused by the model's length validator through
    # the same else branch as the NUL refusal above — the model's sentence, nothing written, no
    # reveal flash — instead of committing the row and losing the reveal-once token to a
    # CookieOverflow 500 on the redirect. The length is counted in characters, the unit the
    # validator and the constant both speak; the byte weight of that character count at the
    # worst four-byte-per-character shape is part of the constant's measured derivation.
    # @intent: {"entity": "POST /repositories/:id/api_keys", "action": "refuse an over-length name", "behavior": "minting a key whose name is one character past ApiKey::NAME_MAX_LENGTH redirects back to the repository page with the model's too-long sentence, writes no key, and reveals no token", "layer": "request"}
    it "redirects with an alert and writes nothing when the name exceeds NAME_MAX_LENGTH" do
      expect {
        post repository_api_keys_path(repository),
             params: { api_key: { name: "x" * (ApiKey::NAME_MAX_LENGTH + 1) } }
      }.not_to change(ApiKey, :count)

      expect(response).to redirect_to(repository_path(repository))
      expect(flash[:alert]).to include("maximum is #{ApiKey::NAME_MAX_LENGTH}")
      expect(flash[:revealed_api_key]).to be_nil
    end

    # SPGD-1878: the cap is a cookie budget, so it is pinned the way SPGD-1075 pinned
    # MAX_NAMES_IN_NOTICE — the REAL constant driven through the REAL mint, sized by the session
    # ceiling check's own arithmetic (`cookie_name.bytesize + value.bytesize`, the inputs
    # `EncryptedKeyRotatingCookieJar#check_for_overflow!` raises on). A constant raised past
    # where the cookie binds fails right here: the mint at the raised cap either raises
    # CookieOverflow inside this example or drives the recorded guard total across
    # MAX_COOKIE_SIZE — never again in production as the post-commit 500 the cap exists to
    # prevent. (NAME_MAX_LENGTH's comment carries the derivation this example holds in place.)
    # @intent: {"entity": "POST /repositories/:id/api_keys", "action": "keep a name at the cap inside the cookie", "behavior": "minting with a name of exactly ApiKey::NAME_MAX_LENGTH characters commits the row, writes the reveal flash, and keeps every serialized session cookie within ActionDispatch::Cookies::MAX_COOKIE_SIZE by the ceiling check's own arithmetic", "layer": "request"}
    it "keeps a name at the cap inside the session cookie's ceiling" do
      guard_totals = []
      allow_any_instance_of(ActionDispatch::Cookies::EncryptedKeyRotatingCookieJar)
        .to receive(:check_for_overflow!).and_wrap_original do |method, cookie_name, options|
          guard_totals << cookie_name.bytesize + options[:value].bytesize
          method.call(cookie_name, options)
        end

      expect {
        post repository_api_keys_path(repository),
             params: { api_key: { name: "n" * ApiKey::NAME_MAX_LENGTH } }
      }.to change(ApiKey, :count).by(1)

      expect(response).to redirect_to(repository_path(repository, anchor: "revealed-key"))
      expect(flash[:revealed_api_key]).to be_present
      expect(flash[:revealed_api_key_name].length).to eq(ApiKey::NAME_MAX_LENGTH)
      expect(repository.api_keys.last.name.length).to eq(ApiKey::NAME_MAX_LENGTH)
      expect(guard_totals).to be_present
      expect(guard_totals.max).to be <= ActionDispatch::Cookies::MAX_COOKIE_SIZE
    end
  end

  describe "revoking (DELETE /repositories/:id/api_keys/:key_id)" do
    let!(:ci_key) { repository.api_keys.create!(name: "CI") }

    # SPGD-804 made revocation a RETIREMENT: the row is retained and stamped `revoked_at` rather
    # than destroyed, because a retained row is the artifact a refused presentation is attributed
    # to (see `Api::BaseController#attribute_refused_revocation`) — a hard delete had left a
    # 401ing pipeline reading "Not connected yet". These two examples pin the fork the way the
    # deleted-row reading used to: the row survives, the token dies, and the redirect and notice
    # are exactly what they always were.
    #
    # @intent: {"entity": "DELETE /repositories/:id/api_keys/:key_id", "action": "revoke as owner", "behavior": "the owner's delete retires the key — row retained, revoked_at stamped, token dead — and redirects to the repository page with the revocation notice", "layer": "request"}
    it "retires the key for the owner, keeping the row" do
      revoked_token = ci_key.raw_token

      expect {
        delete repository_api_key_path(repository, ci_key)
      }.not_to change(ApiKey, :count)

      expect(response).to redirect_to(repository_path(repository))
      # SPGD-1906: the notice names the key (it was the constant "API key revoked." before) — and
      # this key was the repository's only live one, so it also points at a replacement.
      expect(flash[:notice]).to eq("Revoked CI. Its token no longer authenticates. No live API key " \
                                   "remains for this repository — mint a replacement with New API " \
                                   "key so CI can ingest again.")
      expect(ci_key.reload.revoked_at).to be_present
      expect(ApiKey.authenticate(revoked_token)).to be_nil
    end

    # @intent: {"entity": "DELETE /repositories/:id/api_keys/:key_id", "action": "name the revoked key", "behavior": "revoking one of two live keys names it in the notice and adds no replacement pointer, because a live key remains", "layer": "request"}
    it "names the key without a mint pointer when another live key remains" do
      repository.api_keys.create!(name: "Nightly")

      delete repository_api_key_path(repository, ci_key)

      expect(flash[:notice]).to eq("Revoked CI. Its token no longer authenticates.")
    end

    # @intent: {"entity": "DELETE /repositories/:id/api_keys/:key_id", "action": "revoke with keys.manage", "behavior": "a member holding view and keys.manage retires the key the same way — the count is unchanged and revoked_at is stamped", "layer": "request"}
    it "retires the key for a member granted keys.manage" do
      member = create_user(github_uid: "9999", github_handle: "hubot")
      create_membership(repository: repository, user: member, permissions: %w[view keys.manage])
      sign_in_via_github(uid: "9999", info: { nickname: "hubot" })

      expect {
        delete repository_api_key_path(repository, ci_key)
      }.not_to change(ApiKey, :count)

      expect(ci_key.reload).to be_revoked
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
