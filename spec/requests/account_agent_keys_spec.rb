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

  # A POST with no `agent_api_key` root at all is an EMPTY MINT, not a malformed request: it
  # takes the same redirect-and-alert any refused mint takes, rather than a 400 carrying a
  # raised ParameterMissing — the parity `UserApiKeysController` sets for this browser-facing
  # form action.
  # @intent: { entity: "AgentApiKey", action: "answer a bodyless mint", behavior: "POST /account/agent_keys with no params redirects with the model's sentence instead of answering 400", layer: "request" }
  it "answers a mint with no agent_api_key root as a refused grant, not a 400" do
    mint_grant

    expect { post account_agent_keys_path, params: {} }.not_to change(AgentApiKey, :count)

    expect(response).to redirect_to(account_path(anchor: "agent-keys"))
    follow_redirect!
    expect(response.body).to include("must name at least one repository")
  end

  # THE OFFERED SET, pinned the way repository_members_spec pins the member forms' grids: the
  # grid renders from `@grantable_permissions` — the union of `RepositoryPolicy#grantable_permissions`
  # across the offered repositories — so it can never offer a box whose only possible outcome is
  # the model's refusal on submit.
  describe "the mint form's permission grid" do
    # Positive control: an owner holds everything on their own repository, so the whole
    # vocabulary is offered — the narrowing must not over-cut the ordinary case.
    # @intent: { entity: "AgentApiKey", action: "offer the full vocabulary to an owner", behavior: "the account page of a repository owner renders a checkbox for every permission in the vocabulary", layer: "request" }
    it "offers an owner every permission in the vocabulary" do
      mint_grant

      get account_path

      RepositoryMembership::PERMISSIONS.each do |permission|
        expect(response.body).to include("agent_api_key_permissions_#{permission.parameterize}")
      end
    end

    # The regression this narrowing exists to prevent, asserted in the shape
    # repository_members_spec pins on the sibling forms: a view-only grantor sees one box, not
    # four. "view" itself is asserted via its checkbox id — the bare word is all over any page.
    # @intent: { entity: "AgentApiKey", action: "narrow the offered set to what the grantor holds", behavior: "a person whose only access is a view membership is offered the view checkbox and never keys.manage, members.manage or repo.delete", layer: "request" }
    it "offers a view-only grantor exactly what they hold" do
      owner = create_user(github_uid: "91004", github_handle: "grid-owner")
      repository = create_repository(user: owner, github_full_name: "acme/shared-repo")
      create_membership(repository: repository, user: person, permissions: ["view"])

      get account_path

      expect(response.body).to include("agent_api_key_permissions_view")
      expect(response.body).not_to include("keys.manage")
      expect(response.body).not_to include("members.manage")
      expect(response.body).not_to include("repo.delete")
    end

    # The rule of the union most likely to be lost in a rewrite: a row holding only `keys.manage`
    # still offers `view`, because membership itself grants it (`RepositoryPolicy#can?`). The
    # controller's one-read union restates this rule explicitly; this spec is what notices if a
    # future rewrite reads the stored strings without it.
    # @intent: { entity: "AgentApiKey", action: "offer implied view", behavior: "a membership row holding only keys.manage is offered the view checkbox as well", layer: "request" }
    it "offers view to a member whose row omits it" do
      owner = create_user(github_uid: "91005", github_handle: "implied-owner")
      repository = create_repository(user: owner, github_full_name: "acme/implied-view")
      create_membership(repository: repository, user: person, permissions: ["keys.manage"])

      get account_path

      expect(response.body).to include("agent_api_key_permissions_view")
      expect(response.body).to include("agent_api_key_permissions_keys-manage")
    end

    # Ownership of ANY accessible repository dominates the union — the positive control above,
    # exercised over a mixed set so the owner branch is taken across the whole offered list and
    # not only beside an otherwise empty one.
    # @intent: { entity: "AgentApiKey", action: "let ownership dominate the union", behavior: "a person owning one accessible repository is offered the whole vocabulary even beside a view-only shared one", layer: "request" }
    it "offers the whole vocabulary when any accessible repository is owned" do
      mint_grant
      owner = create_user(github_uid: "91006", github_handle: "second-owner")
      shared = create_repository(user: owner, github_full_name: "acme/also-shared")
      create_membership(repository: shared, user: person, permissions: ["view"])

      get account_path

      RepositoryMembership::PERMISSIONS.each do |permission|
        expect(response.body).to include("agent_api_key_permissions_#{permission.parameterize}")
      end
    end

    # THE QUERY BUDGET the union is held to, on the fixture shape the N+1 hid in: SEVERAL shared
    # repositories, where the per-repository spelling this replaced paid one
    # `repository_memberships` read per shared repository (each fresh `RepositoryPolicy` memoized
    # its own `find_by`) and an owned-only fixture could not see it — `can?` short-circuits on
    # `owner?` before touching the row. The page reads this table a CONSTANT number of times:
    # the `accessible_by` boundary read, whose OR-leg is a `repository_memberships` subquery, plus
    # ONE read for the offered-set union. A regression to the N+1 answers 6 here, not "more than
    # one", which is why the count is pinned exactly.
    # @intent: { entity: "AgentApiKey", action: "hold the grid's query budget", behavior: "GET /account reads repository_memberships exactly twice with several shared repositories — the boundary subquery plus one union read, never one per repository", layer: "request" }
    it "reads repository_memberships a constant number of times however many repositories are shared" do
      owner = create_user(github_uid: "91007", github_handle: "budget-owner")
      4.times do |n|
        repository = create_repository(user: owner, github_full_name: "acme/shared-#{n}")
        create_membership(repository: repository, user: person, permissions: ["view"])
      end

      statements = queries_against("repository_memberships") { get account_path }

      expect(statements.size).to eq(2)
    end
  end

  # A person with no accessible repositories has nothing to tick and is offered no permission —
  # every membership implies `view`, so "no boxes" can only mean "no repositories" — and the
  # repositories fieldset's own sentence above already names that state. A legend and prose over
  # an empty grid would describe checkboxes that cannot exist.
  # @intent: { entity: "AgentApiKey", action: "omit the empty permissions fieldset", behavior: "the account page of a person with no repositories renders no Permissions fieldset, while the repositories empty-state sentence still shows", layer: "request" }
  it "renders no permissions fieldset when there is nothing to offer" do
    get account_path

    expect(response.body).not_to include('<legend class="section-label mb-1">Permissions</legend>')
    expect(response.body).to include("No repositories to grant yet")
  end
end
