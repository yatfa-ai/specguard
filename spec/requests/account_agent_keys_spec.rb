# frozen_string_literal: true

require "rails_helper"

# SPGD-952 — the `/account` surface for the agent credential: minting with a grant the owner may
# actually give, the reveal-once discipline, and revocation as a retirement.
RSpec.describe "Account agent keys", type: :request do
  before { @person = sign_in_via_github }

  attr_reader :person

  def mint_grant
    person.repositories.create!(github_full_name: "acme/billing-service")
  end

  def mint(name:, repository_ids:, permissions: [])
    post account_agent_keys_path, params: { agent_api_key: { name: name,
                                                             repository_ids: repository_ids,
                                                             permissions: permissions } }
    follow_redirect!
  end

  # @intent: { entity: "AgentApiKey", action: "mint from the account page", behavior: "POSTing a named grant with repositories and permissions creates the key for this person and the page lists it", layer: "request" }
  it "mints a key carrying the chosen grant" do
    repository = mint_grant

    mint(name: "Fleet agent", repository_ids: [repository.id], permissions: ["view"])

    key = person.agent_api_keys.sole
    expect(key.name).to eq("Fleet agent")
    expect(key.repository_ids).to eq([repository.id])
    expect(key.permissions).to eq(["view"])

    get account_path
    expect(response.body).to include("Fleet agent")
  end

  # @intent: { entity: "AgentApiKey", action: "reveal token once", behavior: "the sga_ plaintext exists only on the mint redirect's render and never again, though the page still shows the hint", layer: "request" }
  it "reveals the raw token exactly once" do
    repository = mint_grant
    mint(name: "Fleet agent", repository_ids: [repository.id])

    token = response.body[/sga_[A-Za-z0-9_-]+/]
    expect(token).to be_present

    get account_path

    expect(response.body).not_to include(token)
    expect(response.body).to include(person.agent_api_keys.sole.token_hint)
  end

  # @intent: { entity: "AgentApiKey", action: "persist digest only", behavior: "the stored row keeps only the SHA-256 digest of the minted token", layer: "request" }
  it "persists only the digest" do
    repository = mint_grant
    mint(name: "Fleet agent", repository_ids: [repository.id])
    token = response.body[/sga_[A-Za-z0-9_-]+/]

    key = person.agent_api_keys.sole

    expect(key.token_digest).to eq(AgentApiKey.digest(token))
  end

  # THE GRANT BOUND, as the minter meets it: a refused save surfaces the MODEL's sentence — which
  # names the repository and the permission — and writes nothing.
  # @intent: { entity: "AgentApiKey", action: "refuse an ungrantable set", behavior: "minting a permission the person does not hold on the chosen repository is refused with the model's sentence and persists nothing", layer: "request" }
  it "refuses a permission the person cannot grant, with the model's sentence" do
    owner = create_user(github_uid: "91001", github_handle: "grant-owner")
    repository = create_repository(user: owner, github_full_name: "acme/someone-elses")

    expect {
      mint(name: "Overreach", repository_ids: [repository.id], permissions: ["members.manage"])
    }.not_to change(AgentApiKey, :count)

    expect(response.body).to include("members.manage on #{repository.github_full_name}")
  end

  # @intent: { entity: "AgentApiKey", action: "refuse an unreachable repository", behavior: "minting over a repository the person cannot open is refused and persists nothing", layer: "request" }
  it "refuses a repository the person cannot open" do
    other = create_user(github_uid: "91002", github_handle: "other")
    repository = create_repository(user: other, github_full_name: "acme/invisible")

    expect {
      mint(name: "Sneak", repository_ids: [repository.id])
    }.not_to change(AgentApiKey, :count)

    expect(response.body).to include("cannot open")
  end

  # REVOCATION IS A RETIREMENT: the token stops authenticating over the API, the row stays so the
  # still-presenting token remains attributable, and the account page keeps showing it.
  # @intent: { entity: "AgentApiKey", action: "revoke from the account page", behavior: "DELETE retires the key so its token answers 401 while the row and the page listing remain", layer: "request" }
  it "revokes the key and the page keeps showing the retired row" do
    repository = mint_grant
    mint(name: "Doomed", repository_ids: [repository.id])
    key = person.agent_api_keys.sole

    delete account_agent_key_path(key)
    follow_redirect!

    expect(key.reload.revoked_at).to be_present
    expect(AgentApiKey.exists?(key.id)).to be(true)

    get account_path
    expect(response.body).to include("Doomed")
  end

  # The association IS the authorization, asserted the way its sibling spec asserts it: one
  # signed-in person cannot reach another's key by typing an id.
  # @intent: { entity: "AgentApiKey", action: "refuse a foreign id", behavior: "DELETE on another person's agent key answers 404 and revokes nothing", layer: "request" }
  it "cannot revoke somebody else's agent key" do
    other = create_user(github_uid: "91003", github_handle: "innocent-bystander")
    foreign = create_agent_api_key(user: other, name: "Not yours")

    expect {
      delete account_agent_key_path(foreign)
    }.not_to change { foreign.reload.revoked_at }

    expect(response).to have_http_status(:not_found)
  end
end
