# frozen_string_literal: true

require "rails_helper"

# SPGD-989 — the repository-side revoke for the agent credential, the lever SPGD-112 gave a
# repository's `keys.manage` holders over `sgk_` keys, carried to `sga_` keys.
#
# The failure this endpoint ends: a member mints an agent key over the repository, their
# membership is later revoked, and the key keeps authenticating — the grant is a MINT-TIME fact
# (`AgentApiKey`'s header) and its only revoker was its owner, from `/account`. These examples
# hold the authorization fork (403 for a member without `keys.manage`, 404 for everybody and
# everything else), the retirement (a stamp on a RETAINED row, the token actually refusing at the
# API), and the `covers?` bound that keeps one repository's `keys.manage` from revoking a key
# that never named it.
RSpec.describe "Revoking an agent key from the repository page", type: :request do
  before { @user = sign_in_via_github }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  # The offboarding shape the endpoint exists for: a member mints, then loses their membership.
  # Nothing cascades into the stored array — the key outlives the grant it was minted under.
  def outlived_key(repository, name: "Fleet agent")
    minter = create_user(github_uid: "7102", github_handle: "departing-dev")
    membership = create_membership(repository: repository, user: minter,
                                   permissions: [RepositoryMembership::VIEW,
                                                 RepositoryMembership::KEYS_MANAGE])
    key = create_agent_api_key(user: minter, repositories: [repository], name: name)
    membership.destroy!
    key
  end

  # AC5 — the whole arc in one example: the token really authenticates while the key outlives its
  # minter, the DELETE retires it, the ROW STAYS (the retirement pattern `ApiKey#revoke!`
  # established), and the token then refuses at the API through the real Bearer path.
  # @intent: {"entity": "AgentApiKey", "action": "revoke from the repository page", "behavior": "a keys.manage holder revokes an outliving agent key so its token answers 401 at the API while the row is retained and leaves the live listing", "layer": "request"}
  it "retires an outliving agent key: the row stays, the token stops, the listing moves on" do
    repository = create_repository(user: @user)
    key = outlived_key(repository)

    # The failure is live before the act: the departed minter's credential still opens the door.
    get "/api/v1/repositories", headers: bearer(key.raw_token)
    expect(response).to have_http_status(:ok)

    expect {
      delete repository_agent_key_path(repository, key)
    }.not_to change(AgentApiKey, :count)

    expect(response).to redirect_to(repository_path(repository))
    follow_redirect!
    expect(flash[:notice]).to include("Revoked #{key.name}")
    expect(key.reload.revoked_at).to be_present

    get "/api/v1/repositories", headers: bearer(key.raw_token)
    expect(response).to have_http_status(:unauthorized)

    # LIVE-only listing (SPGD-804's rule on this table too): the retired row must not present as
    # a live credential on the very page that retired it. Scoped to "no table row in the panel",
    # not to the whole body, and scoped deliberately — the 401 above is a real refused
    # presentation, so it stamped `last_refused_at` (SPGD-991's seam), and since SPGD-1054 the
    # panel names a still-presented revoked key in its own section beside the live table. That
    # naming is the verify half working, not the row presenting as live; what this example pins
    # is that the row never re-enters the listing itself — here, as no row at all, the live
    # listing having emptied.
    get repository_path(repository)
    expect(Capybara.string(response.body).find("#agent-keys")).to have_no_selector("tr", text: key.name)
  end

  # AC8 — the `covers?` bound. A keys.manage holder of repo A may not revoke a key whose stored
  # set excludes A, and the refusal is a 404: out of boundary reads as out of existence, the same
  # fork every repository-scoped read takes.
  # @intent: {"entity": "AgentApiKey", "action": "bound revoke to the acting repository", "behavior": "a keys.manage holder deleting a key that does not cover the acting repository answers 404 and leaves the key live", "layer": "request"}
  it "cannot revoke a key whose set excludes the acting repository" do
    repository = create_repository(user: @user)
    other_repository = create_repository(user: @user, github_full_name: "acme/second-service")
    key = create_agent_api_key(user: @user, repositories: [other_repository], name: "Not yours here")

    expect {
      delete repository_agent_key_path(repository, key)
    }.not_to change { key.reload.revoked_at }

    expect(response).to have_http_status(:not_found)
  end

  # @intent: {"entity": "AgentApiKey", "action": "gate revoke at keys.manage", "behavior": "a member holding only view answers 403 and leaves the key live", "layer": "request"}
  it "refuses a member without keys.manage with 403" do
    repository = create_repository(user: @user)
    key = create_agent_api_key(user: @user, repositories: [repository])
    viewer = create_user(github_uid: "7103", github_handle: "viewer")
    create_membership(repository: repository, user: viewer)

    sign_in_via_github(uid: "7103")
    expect {
      delete repository_agent_key_path(repository, key)
    }.not_to change { key.reload.revoked_at }

    expect(response).to have_http_status(:forbidden)
  end

  # @intent: {"entity": "AgentApiKey", "action": "hide the endpoint from non-members", "behavior": "a non-member deleting through the repository path answers 404", "layer": "request"}
  it "answers 404 for a non-member" do
    repository = create_repository(user: @user)
    key = create_agent_api_key(user: @user, repositories: [repository])

    sign_in_via_github(uid: "7104", handle: "stranger")
    delete repository_agent_key_path(repository, key)

    expect(response).to have_http_status(:not_found)
  end

  # A revoked row is retained but is not a credential — `keys_minted_by` already refuses to count
  # one (SPGD-804) — so the action's `live` lookup finds nothing and the replay is a 404.
  # @intent: {"entity": "AgentApiKey", "action": "refuse a replayed revoke", "behavior": "deleting an already-revoked key answers 404 and re-stamps nothing", "layer": "request"}
  it "does not find a revoked key" do
    repository = create_repository(user: @user)
    key = create_agent_api_key(user: @user, repositories: [repository]).revoke!
    stamped_at = key.reload.revoked_at

    delete repository_agent_key_path(repository, key)

    expect(response).to have_http_status(:not_found)
    expect(key.reload.revoked_at).to eq(stamped_at)
  end
end
