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

  # SPGD-1898: the form root and the name are read shape-safely. A scalar `agent_api_key=x` root
  # used to raise NoMethodError on `permit` (HTML 500); it is now an empty mint, which the model
  # refuses with its own sentence. A Hash or Array `name` used to be stored as its inspect string.
  # @intent: { entity: "AgentApiKey", action: "mint with a scalar agent_api_key root", behavior: "posting agent_api_key as a bare scalar redirects back to /account with the model's empty-mint refusal and writes no key instead of raising a 500", layer: "request" }
  it "redirects with an alert and writes nothing when the agent_api_key root is a scalar" do
    expect {
      post account_agent_keys_path, params: { agent_api_key: "x" }
    }.not_to change(AgentApiKey, :count)

    expect(response).to redirect_to(account_path(anchor: "agent-keys"))
    expect(flash[:alert]).to be_present
  end

  # @intent: { entity: "AgentApiKey", action: "mint with a non-String name", behavior: "posting a Hash or an Array as the agent key name with a valid grant mints one key named Agent key rather than storing the value's Ruby inspect string", layer: "request" }
  it "mints an Agent key when the name is a Hash or an Array" do
    repository = mint_grant

    [{ a: "b" }, ["b"]].each do |shape|
      expect {
        post account_agent_keys_path,
             params: { agent_api_key: { name: shape, repository_ids: [repository.id] } }
      }.to change(AgentApiKey, :count).by(1)

      expect(AgentApiKey.order(:created_at).last.name).to eq("Agent key")
    end
  end

  # SPGD-1476: a NUL in the name is refused by the model's format validator, so the mint takes the
  # same else branch as the grant refusals above — redirect with an alert — and writes nothing,
  # instead of raising at INSERT (Postgres cannot store a NUL). The double-quoted literal is
  # load-bearing: a single-quoted '\u0000' is six printable characters and must still mint.
  # @intent: { entity: "AgentApiKey", action: "refuse a NUL in the name", behavior: "minting a key whose name carries a NUL redirects back to /account with an alert and writes no key", layer: "request" }
  it "redirects with an alert and writes nothing when the name carries a NUL" do
    repository = mint_grant

    expect {
      post account_agent_keys_path, params: { agent_api_key: { name: "Fleet\u0000agent",
                                                               repository_ids: [repository.id] } }
    }.not_to change(AgentApiKey, :count)

    expect(response).to redirect_to(account_path(anchor: "agent-keys"))
    expect(flash[:alert]).to be_present
  end

  # SPGD-1878: a name past NAME_MAX_LENGTH is refused by the model's length validator through the
  # same else branch as the NUL refusal above — the model's sentence, nothing written, no reveal
  # flash — instead of committing the row and losing the reveal-once token to a CookieOverflow
  # 500 on the redirect. The length is counted in characters, the unit the validator and the
  # constant both speak.
  # @intent: { entity: "AgentApiKey", action: "refuse an over-length name", behavior: "minting a key whose name is one character past AgentApiKey::NAME_MAX_LENGTH redirects back to /account with the model's too-long sentence and writes no key", layer: "request" }
  it "redirects with an alert and writes nothing when the name exceeds NAME_MAX_LENGTH" do
    repository = mint_grant

    expect {
      post account_agent_keys_path,
           params: { agent_api_key: { name: "x" * (AgentApiKey::NAME_MAX_LENGTH + 1),
                                      repository_ids: [repository.id] } }
    }.not_to change(AgentApiKey, :count)

    expect(response).to redirect_to(account_path(anchor: "agent-keys"))
    expect(flash[:alert]).to include("maximum is #{AgentApiKey::NAME_MAX_LENGTH}")
    expect(flash[:revealed_agent_api_key]).to be_nil
  end

  # SPGD-1878: the cap is a cookie budget, pinned the way SPGD-1075 pinned MAX_NAMES_IN_NOTICE —
  # the REAL constant driven through the REAL mint, sized by the session ceiling check's own
  # arithmetic. A constant raised past where the cookie binds fails right here, never again in
  # production as the post-commit 500 the cap exists to prevent. (NAME_MAX_LENGTH's comment
  # carries the derivation this example holds in place.)
  # @intent: { entity: "AgentApiKey", action: "keep a name at the cap inside the cookie", behavior: "minting with a name of exactly AgentApiKey::NAME_MAX_LENGTH characters commits the row, writes the reveal flash, and keeps every serialized session cookie within ActionDispatch::Cookies::MAX_COOKIE_SIZE by the ceiling check's own arithmetic", layer: "request" }
  it "keeps a name at the cap inside the session cookie's ceiling" do
    repository = mint_grant
    guard_totals = []
    allow_any_instance_of(ActionDispatch::Cookies::EncryptedKeyRotatingCookieJar)
      .to receive(:check_for_overflow!).and_wrap_original do |method, cookie_name, options|
        guard_totals << cookie_name.bytesize + options[:value].bytesize
        method.call(cookie_name, options)
      end

    expect {
      post account_agent_keys_path,
           params: { agent_api_key: { name: "n" * AgentApiKey::NAME_MAX_LENGTH,
                                      repository_ids: [repository.id] } }
    }.to change(AgentApiKey, :count).by(1)

    expect(response).to redirect_to(account_path(anchor: "revealed-agent-key"))
    expect(flash[:revealed_agent_api_key]).to be_present
    expect(flash[:revealed_agent_api_key_name].length).to eq(AgentApiKey::NAME_MAX_LENGTH)
    expect(person.agent_api_keys.sole.name.length).to eq(AgentApiKey::NAME_MAX_LENGTH)
    expect(guard_totals).to be_present
    expect(guard_totals.max).to be <= ActionDispatch::Cookies::MAX_COOKIE_SIZE
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

  # SPGD-1925 — THE BLAST RADIUS, NAMED ON /account. The key's own minter gets the same
  # disclosure the repository-side panel gives its `keys.manage` holders: the Repositories cell
  # renders count first and the names the minter can open beside it, the Revoke confirm names
  # the set before the cut, and the flash names it after. /account is self-scoped —
  # `AccountsController` indexes the name map off `@grantable_repositories` — so a stored id
  # with no name (deleted since mint, or access since lost) is disclosed as a COUNT and never
  # named: a repository the viewer cannot open must stay indistinguishable from one that does
  # not exist.
  describe "the covered-set disclosure" do
    def row_for(name)
      Capybara.string(response.body).find("tr", text: name)
    end

    # @intent: { entity: "AgentApiKey", action: "name the covered set on /account", behavior: "a two-repository key's Repositories cell renders the count and both covered repository names", layer: "request" }
    it "names the covered repositories of a two-repository key" do
      alpha = create_repository(user: person, github_full_name: "acme/alpha")
      beta = create_repository(user: person, github_full_name: "acme/beta")
      create_agent_api_key(user: person, repositories: [alpha, beta], name: "Fleet")

      get account_path

      row = row_for("Fleet")
      expect(row).to have_text("2")
      expect(row).to have_text("acme/alpha, acme/beta")
    end

    # The deleted limb: nothing cascades into the stored array, so a set of two can carry one
    # name, and the cell discloses the difference instead of letting "2" sit beside one name.
    # @intent: { entity: "AgentApiKey", action: "disclose a since-deleted repository", behavior: "a key whose stored repository was deleted renders the surviving name and the unnamed-count line, never the deleted name", layer: "request" }
    it "discloses a repository deleted since mint as a count" do
      alpha = create_repository(user: person, github_full_name: "acme/alpha")
      doomed = create_repository(user: person, github_full_name: "acme/doomed")
      create_agent_api_key(user: person, repositories: [alpha, doomed], name: "Fleet")
      doomed.destroy!

      get account_path

      row = row_for("Fleet")
      expect(row).to have_text("acme/alpha")
      expect(row).not_to have_text("acme/doomed")
      expect(row).to have_text("1 repository deleted or no longer open to you")
    end

    # The lost-access limb, the one /account's wider `missing_phrase:` exists for: a ticked
    # repository the minter can no longer open keeps its id on the key (the mint form's own
    # sentence names exactly this state), the page never names it, and the row says so as a
    # count. Asserted against the WHOLE body, not just the row — the lost repository drops out
    # of the mint grid beside the table too, so a partial match could hide a leak.
    # @intent: { entity: "AgentApiKey", action: "withhold a lost-access name", behavior: "after the minter loses access to a covered repository its name is rendered nowhere on /account and the row discloses the unnamed count", layer: "request" }
    it "never names a covered repository the minter can no longer open" do
      alpha = create_repository(user: person, github_full_name: "acme/alpha")
      shared = create_repository(user: create_user(github_uid: "91009", github_handle: "leaver-owner"),
                                 github_full_name: "acme/revoked-share")
      create_membership(repository: shared, user: person, permissions: ["view"])
      create_agent_api_key(user: person, repositories: [alpha, shared], name: "Fleet")
      RepositoryMembership.find_by!(repository: shared, user: person).destroy!

      get account_path

      row = row_for("Fleet")
      expect(row).to have_text("acme/alpha")
      expect(response.body).not_to include("acme/revoked-share")
      expect(row).to have_text("1 repository deleted or no longer open to you")
    end

    # THE CONFIRM: the presser is told the count and the names of the set the cut spans BEFORE
    # it happens — the one-act honesty the repository-side dialog established.
    # @intent: { entity: "AgentApiKey", action: "disclose the blast radius in the revoke confirm", behavior: "the Revoke button's turbo_confirm names the covered count, the covered names, and that revoking cuts the token on every repository in that set", layer: "request" }
    it "names the covered set in the revoke confirm" do
      alpha = create_repository(user: person, github_full_name: "acme/alpha")
      beta = create_repository(user: person, github_full_name: "acme/beta")
      create_agent_api_key(user: person, repositories: [alpha, beta], name: "Fleet")

      get account_path

      expect(response.body).to include("Revoke Fleet? It covers 2 repositories: acme/alpha, acme/beta. " \
                                       "Revoking it here cuts the token on every repository in that set")
    end

    # THE AFTER-CUT HALF: the flash names the key and the set it covered, in the same sentence
    # shape the repository-side revoker serves its `keys.manage` holders.
    # @intent: { entity: "AgentApiKey", action: "name the covered set after revoke", behavior: "the post-revoke flash names the revoked key and the repositories its stored set covered", layer: "request" }
    it "names the key and its covered set in the notice after revoke" do
      alpha = create_repository(user: person, github_full_name: "acme/alpha")
      beta = create_repository(user: person, github_full_name: "acme/beta")
      key = create_agent_api_key(user: person, repositories: [alpha, beta], name: "Fleet")

      delete account_agent_key_path(key)

      expect(response).to redirect_to(account_path)
      expect(flash[:notice]).to eq("Revoked Fleet. It covered 2 repositories: acme/alpha, acme/beta — " \
                                   "its token no longer authenticates anywhere.")
    end

    # The unnamed limb on the notice, self-scoped like the page: the destroy action reads its
    # names off the minter's OWN reachable set, so a lost-access repository is disclosed as a
    # count and its name reaches no flash either.
    # @intent: { entity: "AgentApiKey", action: "withhold a lost-access name after revoke", behavior: "revoking a key covering a repository the minter can no longer open answers a flash disclosing the unnamed count without ever naming that repository", layer: "request" }
    it "discloses an unnamed repository in the revoke notice without naming it" do
      alpha = create_repository(user: person, github_full_name: "acme/alpha")
      shared = create_repository(user: create_user(github_uid: "91010", github_handle: "leaver-owner-2"),
                                 github_full_name: "acme/revoked-share-2")
      create_membership(repository: shared, user: person, permissions: ["view"])
      key = create_agent_api_key(user: person, repositories: [alpha, shared], name: "Fleet")
      RepositoryMembership.find_by!(repository: shared, user: person).destroy!

      delete account_agent_key_path(key)

      expect(flash[:notice])
        .to include("2 repositories: acme/alpha (1 repository since deleted or no longer open to you)")
      expect(flash[:notice]).not_to include("acme/revoked-share-2")
    end

    # THE REPLAY PATH: a second DELETE resolves the row through the association (no `live`
    # scope), composes the same honest sentence from the same self-scoped read, and `revoke!`
    # re-stamps nothing — the FIRST stamp stays the offboarding date.
    # @intent: { entity: "AgentApiKey", action: "answer a replayed revoke", behavior: "a second DELETE on an already-revoked key redirects with the same covered-set notice and keeps the first revocation stamp", layer: "request" }
    it "answers a replayed revoke with the same covered-set notice and no re-stamp" do
      alpha = create_repository(user: person, github_full_name: "acme/alpha")
      key = create_agent_api_key(user: person, repositories: [alpha], name: "Fleet")
      delete account_agent_key_path(key)
      first_stamp = key.reload.revoked_at

      delete account_agent_key_path(key)

      expect(response).to redirect_to(account_path)
      expect(flash[:notice]).to eq("Revoked Fleet. It covered 1 repository: acme/alpha — " \
                                   "its token no longer authenticates anywhere.")
      expect(key.reload.revoked_at).to eq(first_stamp)
    end
  end

  # SPGD-991 — the whole story this column exists for, read across both surfaces: the owner
  # revokes here, the leaked token keeps knocking at the agent API (401, stamped), and the row
  # on THIS page dates the last observed presentation. `last_refused_at` is the LAST time the
  # platform saw it — the line dates an observation, never a present tense
  # (_connection_indicator.html.erb's rule).
  # @intent: { entity: "AgentApiKey", action: "date the last refused presentation", behavior: "a revoked key whose token was refused since renders 'last presented N ago' beneath the Revoked badge", layer: "request" }
  it "dates the last refused presentation on a revoked key the platform has seen since" do
    repository = mint_grant
    mint(name: "Leaked", repository_ids: [repository.id])
    leaked_token = response.body[/sga_[A-Za-z0-9_-]+/]
    key = person.agent_api_keys.sole

    delete account_agent_key_path(key)
    follow_redirect!

    # The still-presenting token, presented for real: the failure path stamps it (SPGD-991's seam).
    get "/api/v1/repositories", headers: { "Authorization" => "Bearer #{leaked_token}" }
    expect(response).to have_http_status(:unauthorized)
    expect(key.reload.last_refused_at).to be_present

    get account_path

    expect(response.body).to include("Revoked")
    expect(response.body).to match(/last presented .+ ago/i)
  end

  # SPGD-1104 — the value-level pin of the line the example above dates. That example's
  # /last presented .+ ago/i holds the LINE, never the stamp feeding it, and its same-second
  # fixture renders every candidate (created_at, revoked_at, last_refused_at) as "less than a
  # minute", so swapping the cell's source (show.html.erb:269) leaves it green — measured. The
  # example below puts each stamp in its own time_ago bucket through the model's real writers —
  # minted at 90 days, revoked at 6 days, the refused presentation stamped NOW — and holds the
  # cell to its own value: the age can only read "less than a minute" from `last_refused_at`, so
  # a swap to `revoked_at` ("6 days") or `created_at` ("3 months") fails here. The /account twin
  # of the repository panel's pin (SPGD-1088).
  describe "the still-presented age's source" do
    # `travel_to` — the same scoping `repositories_spec` states in full for its panel's twin:
    # no other example in this file moves the clock, and the include stays off every spec that
    # has done without it.
    include ActiveSupport::Testing::TimeHelpers

    def row_for(name)
      Capybara.string(response.body).find("tr", text: name)
    end

    # @intent: {"entity": "AgentApiKey", "action": "date the presented age", "behavior": "a still-presented agent key whose mint, revocation and last refusal fall in three different time_ago buckets reads last presented less than a minute on its own row, the age held to its own stamp", "layer": "request"}
    it "dates the presented age from its own stamp" do
      repository = mint_grant
      key = travel_to(90.days.ago) do
        create_agent_api_key(user: person, repositories: [repository], name: "Six-day leak")
      end
      travel_to(6.days.ago) { key.revoke! }
      key.touch_last_refused!

      get account_path

      expect(row_for("Six-day leak"))
        .to have_text(/last\s+presented\s+less than a minute\s+ago/)
    end
  end

  # SPGD-1112 — the /account twin of the Last used CELL's own pin (repositories_spec.rb:912,
  # landed SPGD-1108), which that example could not cover: this table's cell at
  # show.html.erb:242 renders on every landed example here and nothing asserted it — zero
  # assertions on the axis, and `touch_last_used!` (the writer Api::BaseController invokes on
  # every successful presentation) never once referenced. A value-branch swap to the mint
  # would leave the whole file green: the condition's nil branch and the interpolation are
  # two independently pinnable halves, and only the nil branch is pinned anywhere on /account
  # today. This example holds BOTH: the fresh key's "never" pins the nil branch, then
  # `touch_last_used!` splits the candidates through the model's real writer — minted at
  # 90 days, presented NOW — so "less than a minute" can only come from `last_used_at`
  # (the mint reads "3 months" in the Created cell beside it), and the swap fails here.
  describe "the Last used cell's source" do
    # `travel_to` — the same scoping the sibling describe above states: no other example in
    # this file moves the clock, and the include stays off every spec that has done without it.
    include ActiveSupport::Testing::TimeHelpers

    def row_for(name)
      Capybara.string(response.body).find("tr", text: name)
    end

    # @intent: {"entity": "AgentApiKey", "action": "date the Last used cell", "behavior": "an /account agent-key row whose mint and last presentation fall in different time_ago buckets reads the Last used cell from the presentation stamp and not the mint, with the untouched key's never holding the nil branch", "layer": "request"}
    it "dates the Last used cell from last_used_at, not the mint" do
      repository = mint_grant
      key = travel_to(90.days.ago) do
        create_agent_api_key(user: person, repositories: [repository], name: "Daily driver")
      end

      get account_path
      expect(row_for("Daily driver")).to have_text("never")

      key.touch_last_used!
      get account_path

      row = row_for("Daily driver")
      expect(row).to have_text("less than a minute")
      expect(row).to have_text("3 months")
    end
  end

  # The honest half: a revoked key the platform never saw again carries no refusal datum, and the
  # row renders exactly as it did before this column existed — the state was never OBSERVED, so it
  # is absent rather than rendered as "never".
  # @intent: { entity: "AgentApiKey", action: "not invent a presentation", behavior: "a revoked key with last_refused_at nil renders the Revoked badge with no presented line, exactly as before", layer: "request" }
  it "renders a revoked key never refused again without a presented line" do
    repository = mint_grant
    mint(name: "Quietly retired", repository_ids: [repository.id])
    key = person.agent_api_keys.sole

    delete account_agent_key_path(key)
    follow_redirect!

    get account_path

    expect(key.reload.last_refused_at).to be_nil
    expect(response.body).to include("Quietly retired")
    expect(response.body).to include("Revoked")
    expect(response.body).not_to match(/last presented/i)
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

  # SPGD-1588 — the caption once said an sga_ key "could not post CI results" while the grid beside
  # it offered the runs.ingest box (true since SPGD-984). Caption and grid are pinned together so
  # one cannot drift from the other again.
  # @intent: { entity: "AgentApiKey", action: "describe the ingest grant", behavior: "the Agent keys caption names runs.ingest and the repository-scoped ingest route, never denies keys the ability to ingest, keeps registering and renaming person-only, and the grid still offers the runs.ingest box", layer: "request" }
  it "describes the ingest grant in the caption and offers the matching box" do
    mint_grant

    get account_path

    caption = Capybara.string(response.body).find("#agent-keys-caption").text.squish
    expect(caption).not_to match(/cannot\s+ingest/i)
    expect(caption).to include(RepositoryMembership::RUNS_INGEST)
    expect(caption).to include("/api/v1/repositories/")
    expect(caption).to match(/registering and renaming stay person-only/)

    expect(Capybara.string(response.body))
      .to have_css("#agent_api_key_permissions_#{RepositoryMembership::RUNS_INGEST.parameterize}")
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

    # `repo.delete` is a STORABLE permission, not an owner-only one — `RepositoryPolicy::CAPABILITIES`
    # maps `:repo_delete` to the stored string (only `:owner` maps to the `OWNER_ONLY` sentinel),
    # the policy answers `can?(:repo_delete)` off the row, and `RepositoriesController#destroy`
    # gates at it for exactly that reason. A member holding it may hand it to a human colleague
    # through the members form, so this grid must offer it too: subtracting it here would hide a
    # box the model accepts — the inverse of the over-offer the grid exists to prevent, and it
    # diverges from the policy on every row shape carrying `repo.delete`. The regression this
    # guards is a rewrite "simplifying" the union by assuming only owners can hold it.
    # @intent: { entity: "AgentApiKey", action: "offer repo.delete to a member who holds it", behavior: "a membership row carrying repo.delete is offered the repo.delete checkbox beside view, and no permission the member does not hold", layer: "request" }
    it "offers repo.delete to a member whose row carries it" do
      owner = create_user(github_uid: "91008", github_handle: "deletable-owner")
      repository = create_repository(user: owner, github_full_name: "acme/deletable")
      create_membership(repository: repository, user: person, permissions: ["view", "repo.delete"])

      get account_path

      expect(response.body).to include("agent_api_key_permissions_view")
      expect(response.body).to include("agent_api_key_permissions_repo-delete")
      expect(response.body).not_to include("keys.manage")
      expect(response.body).not_to include("members.manage")
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
