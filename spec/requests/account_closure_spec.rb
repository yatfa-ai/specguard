# frozen_string_literal: true

require "rails_helper"

# SPGD-853 — closing the account from `/account`, the first writer `users.archived_at` has ever
# had, and the endpoint that makes SPGD-358's three enforcement points reachable without a Rails
# console.
#
# Everything here goes through the real routes, for the same reason
# `account_github_installations_spec.rb` states: the claim under test is that a PERSON can do this
# from a page. And because the state is the one the app already polices, the assertions are aimed
# at those enforcement points themselves — a live session that stops authenticating through the
# real `current_user` path (not the session hash), an `sgu_` token refused by the real
# `UserApiKey.authenticate` stack over HTTP, a sign-in refused by the real callback — rather than
# at the column value alone.
RSpec.describe "Account closure", type: :request do
  # The colleague whose rows and access must survive the person's closure untouched — passed an
  # explicit uid, which only has to differ from the person's: one identity per suite process
  # (`Builders::DEFAULT_GITHUB_UID`), and a literal like "2002" will not be it.
  def colleague = @colleague ||= create_user(github_uid: "2002", github_handle: "hubot",
                                             installation_id: nil)

  # Keyword arguments become TOP-LEVEL request parameters through the splat — `close_account(id: 7)`
  # posts `id=7`, never `params[id]=7`. The criterion-6 example depends on that contract: its
  # adversarial parameters must arrive where a params-with-fallback regression would read them.
  def close_account(**params)
    post close_account_path, params: params
    follow_redirect!
  end

  # The page from the panel down — same scissor as `account_github_installations_spec`, so a
  # claim about the closure panel's copy cannot be satisfied by some other panel's sentence.
  def closure_panel = response.body[response.body.index('id="account-closure"')..]

  before { @person = sign_in_via_github }

  attr_reader :person

  # SPGD-853 criterion 1 — one confirmed gesture: the row's `archived_at` goes from NULL to a
  # timestamp, and the person lands signed-out on the root page.
  # @intent: { entity: "User", action: "close account from the page", behavior: "POST /account/close from a signed-in session stamps the current user's archived_at from nil to a timestamp and redirects to the root path, where the closure notice renders", layer: "request" }
  it "closes the account in one gesture and says so on the way out" do
    expect(person.reload.archived_at).to be_nil

    close_account

    expect(person.reload.archived_at).to be_present
    expect(response).to have_http_status(:ok) # the followed root render
    expect(response.body).to include("Your account is closed")
  end

  # SPGD-853 criterion 2 — the session is ended by the closure, exercised through the real
  # `current_user` path: `ApplicationController` scopes to `User.active`, so the next
  # authenticated request must behave exactly as a signed-out visitor's does.
  # @intent: { entity: "Session", action: "end session on closure", behavior: "after POST /account/close the same session GETs /repositories and is redirected to root with the sign-in alert, proving the live session stopped authenticating without asserting on the session hash", layer: "request" }
  it "leaves the session it just killed behaving as signed out" do
    get repositories_path
    expect(response).to have_http_status(:ok)

    close_account

    get repositories_path

    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response.body).to include("Sign in with GitHub to continue")
  end

  # SPGD-853 criterion 3 — the `sgu_` half, before and after, over HTTP so
  # `UserApiKey.authenticate` is exercised through the whole stack rather than called directly:
  # the same accepted-then-refused shape `spec/models/user_api_key_spec.rb` pins at the model.
  # @intent: { entity: "UserApiKey", action: "refuse closed owner token", behavior: "a personal API key answers GET /api/v1/repositories with 200 before its owner closes the account and 401 after, while the key row itself survives", layer: "request" }
  it "refuses the personal keys of a closed account that worked a moment earlier" do
    key = create_user_api_key(user: person, name: "Laptop")

    get "/api/v1/repositories", headers: { "Authorization" => "Bearer #{key.raw_token}" }
    expect(response).to have_http_status(:ok)

    close_account

    get "/api/v1/repositories", headers: { "Authorization" => "Bearer #{key.raw_token}" }
    expect(response).to have_http_status(:unauthorized)
    # Refused, not destroyed — the row stays for audit, which is the whole point of archiving.
    expect(UserApiKey.exists?(key.id)).to be(true)
  end

  # SPGD-853 criterion 4 — closure is one-way, and the proof is the door on the way back in:
  # the real callback must refuse, exactly as it refuses a console-archived person, rather than
  # silently reactivate.
  # @intent: { entity: "Session", action: "refuse closed account sign-in", behavior: "after POST /account/close a fresh GitHub callback for the same uid changes no User count, leaves archived_at untouched, redirects to root with the archived alert including the in-product-irreversible sentence", layer: "request" }
  it "refuses the closed account at sign-in instead of reactivating it" do
    close_account
    archived_at = person.reload.archived_at

    expect { sign_in_via_github(installation: false) }.not_to change(User, :count)

    expect(response).to redirect_to(root_path)
    expect(person.reload.archived_at).to eq(archived_at)

    follow_redirect!
    expect(response.body).to include("has been archived")
    # The honesty half of the refusal: a person who closed it themselves must be told there is
    # no undo in the product, not pointed at an admin authority the product does not have.
    expect(response.body).to include("cannot be undone from within SpecGuard")
  end

  # SPGD-853 criterion 5 — the `not_to change(&counts)` idiom from
  # `spec/models/user_spec.rb` ("destroys and nullifies nothing"), restated over HTTP: the
  # closure endpoint must hold the same invariant the model state was specified to hold.
  # @intent: { entity: "User", action: "destroy nothing on closure", behavior: "POST /account/close changes no row counts across repositories, runs, intents, both key kinds, memberships, installations and grants, and leaves every attribution column still naming the closed person", layer: "request" }
  it "destroys and nullifies nothing but the session" do
    repository = create_repository(user: person)
    test_run = create_test_run(repository: repository)
    spec_intent = create_spec_intent(repository: repository)
    repo_key = repository.api_keys.create!(name: "CI — main", created_by_user: person)
    personal_key = create_user_api_key(user: person, name: "Laptop")
    granted = create_membership(repository: repository, user: colleague)
    granted.update!(granted_by_user: person)
    received = create_membership(repository: create_repository(user: colleague,
                                                              github_full_name: "hubot/scratch"),
                                 user: person)
    create_registration_grant(user: person)

    counts = lambda do
      [Repository.count, TestRun.count, SpecIntent.count, ApiKey.count, UserApiKey.count,
       RepositoryMembership.count, GithubInstallation.count, GithubRegistrationGrant.count]
    end

    expect { close_account }.not_to change(&counts)

    expect(person.reload).to be_archived
    # "Still there" is not enough if the columns pointing at the person were nulled — same
    # second half as the model spec this mirrors.
    expect(repository.reload.user).to eq(person)
    expect(test_run.reload.repository).to eq(repository)
    expect(spec_intent.reload.repository).to eq(repository)
    expect(repo_key.reload.created_by_user).to eq(person)
    expect(person.user_api_keys).to contain_exactly(personal_key)
    expect(granted.reload.user).to eq(colleague)
    expect(granted.granted_by_user).to eq(person)
    expect(received.reload.user).to eq(person)
  end

  # SPGD-853 criterion 6 — the endpoint takes no parameter that names a victim: whatever a
  # request carries, the session alone answers whose account closes.
  # @intent: { entity: "User", action: "scope closure to the session", behavior: "POST /account/close carrying another user's id, user_id and github_uid parameters archives only the current user and leaves the other account active", layer: "request" }
  it "closes nobody's account but the session holder's, whatever the request names" do
    # Sent as top-level request parameters (not nested under a params key) — exactly where a
    # `params[:user_id]` lookup with a `current_user` fallback would find them.
    close_account(id: colleague.id, user_id: colleague.id,
                  github_uid: colleague.github_uid)

    expect(person.reload).to be_archived
    expect(colleague.reload).not_to be_archived
    expect(colleague.reload.archived_at).to be_nil
  end

  # The gate in front of the endpoint: a request with no session behind it reaches nobody's
  # row. Signed out through the real route, as `sessions_spec` does — the claim is about what
  # the endpoint sees, not about how the session was emptied.
  # @intent: { entity: "User", action: "require sign-in to close", behavior: "a signed-out POST /account/close is redirected to root with the sign-in alert and no user row gains an archived_at", layer: "request" }
  it "asks for a session before it closes anything" do
    delete sign_out_path

    expect { post close_account_path }.not_to change { User.where.not(archived_at: nil).count }

    expect(response).to redirect_to(root_path)
  end

  # The confirm dialog and panel copy are part of the contract: the three consequences the code
  # actually enforces, plus the one-way door, said where the person actually reads them.
  # @intent: { entity: "User", action: "state closure consequences", behavior: "GET /account renders a Close account panel whose copy names the no-sign-in, immediate-key-refusal and nothing-destroyed consequences and the cannot-reopen-from-within door", layer: "request" }
  it "names all three consequences and the one-way door on the page itself" do
    get account_path

    expect(response).to have_http_status(:ok)
    panel = closure_panel
    expect(panel).to include("Close account")
    expect(panel).to include("cannot be reopened from within SpecGuard")
    expect(panel).to include("cannot sign in again")
    expect(panel).to include("stops authenticating")
    expect(panel).to include("Nothing is destroyed")
  end

  # SPGD-1934 — the disclosure is quantified from the person's own rows: a person closing an
  # account that still carries live automation is told exactly what stops, in BOTH places the
  # consequence is read (the panel bullet and the confirm dialog), because the two must not
  # drift. The agent-key count is the live half only, and its coverage is the DISTINCT
  # repositories the stored sets span — the same count-first rule
  # `RepositoriesHelper#agent_key_coverage_sentence` counts one key by, folded across keys.
  # @intent: { entity: "User", action: "quantify the closure disclosure", behavior: "GET /account with one live personal key and two live agent keys whose stored sets span three repositories renders the Close-account panel and its turbo_confirm naming 1 live sgu_ token and 2 live agent keys covering 3 repositories, and splits the what-remains sentence into CI keys keep working and personal/agent tokens dead", layer: "request" }
  it "names the live key counts and agent-key coverage in the panel and the confirm" do
    create_user_api_key(user: person, name: "Laptop")
    alpha = create_repository(user: person, github_full_name: "acme/alpha")
    beta = create_repository(user: person, github_full_name: "acme/beta")
    gamma = create_repository(user: person, github_full_name: "acme/gamma")
    create_agent_api_key(user: person, repositories: [alpha, beta], name: "Fleet")
    create_agent_api_key(user: person, repositories: [beta, gamma], name: "Scout")

    get account_path

    panel = closure_panel
    expect(panel).to include("your 1 live <code class=\"font-mono text-xs\">sgu_</code> token — " \
                             "and so does every agent key you minted: 2 live agent keys, covering " \
                             "3 repositories, stop working immediately")
    expect(panel).to include("keep authenticating — closure does not touch them")
    expect(panel).to include("their tokens dead")

    expect(panel).to include("Every sgu_ API key you hold stops working immediately — 1 live token — " \
                             "and so does every agent key you minted: 2 live agent keys, covering " \
                             "3 repositories, stop working immediately, including keys on machines " \
                             "you no longer have.")
    expect(panel).to include("Repository CI keys keep working; your personal and agent keys " \
                             "remain as rows with dead tokens.")
  end

  # The personal half alone: a person holding live `sgu_` tokens but no agent keys gets the
  # count on that half and no agent-key sentence — there is no agent cut to name, and saying
  # nothing about agent keys is the honest zero for them.
  # @intent: { entity: "UserApiKey", action: "quantify only the personal half", behavior: "GET /account with one live personal key and no agent keys renders the closure panel naming 1 live sgu_ token with no agent-key sentence, and the confirm naming 1 live token", layer: "request" }
  it "quantifies the personal keys alone when no agent keys are live" do
    create_user_api_key(user: person, name: "Laptop")

    get account_path

    panel = closure_panel
    expect(panel).to include("your 1 live <code class=\"font-mono text-xs\">sgu_</code> token, " \
                             "including keys still running on machines you no longer have.")
    expect(panel).not_to include("agent key you minted")
    expect(panel).to include("Every sgu_ API key you hold stops working immediately — 1 live token, " \
                             "including keys on machines you no longer have.")
  end

  # A revoked `sga_` row already authenticates nothing, so it is not counted as something the
  # closure cuts — the count names the live cut only. The row itself is still retained, so the
  # what-remains truths still apply to it.
  # @intent: { entity: "AgentApiKey", action: "exclude revoked keys from the closure count", behavior: "GET /account with only a revoked agent key renders no live agent-key count in the closure panel while the what-remains truths still describe the retained row", layer: "request" }
  it "does not count a revoked agent key among the keys the closure cuts" do
    alpha = create_repository(user: person, github_full_name: "acme/alpha")
    key = create_agent_api_key(user: person, repositories: [alpha], name: "Fleet")
    key.revoke!

    get account_path

    panel = closure_panel
    expect(panel).not_to include("live agent key")
    expect(panel).to include("every <code class=\"font-mono text-xs\">sgu_</code> token")
    expect(panel).to include("their tokens dead")
  end

  # The zero-state contract: an owner holding neither credential kind keeps the standing
  # generic sentences verbatim, in panel and confirm — no zero counts, no agent-key sentence,
  # nothing invented to quantify.
  # @intent: { entity: "User", action: "keep the unquantified copy for a keyless owner", behavior: "GET /account for an owner holding no personal or agent keys renders the closure panel and its turbo_confirm with the standing generic sentences and no live counts or agent-key sentence", layer: "request" }
  it "keeps the unquantified copy for an owner holding no keys" do
    get account_path

    panel = closure_panel
    expect(panel).to include("every <code class=\"font-mono text-xs\">sgu_</code> token, " \
                             "including keys still running on machines you no longer have.")
    expect(panel).not_to include("live agent key")
    expect(panel).not_to include("live sgu_")
    expect(panel).not_to include("covering")
    expect(panel).to include("the keys you minted and the memberships you granted all remain, " \
                             "with your name still on them")

    expect(panel).to include("Every sgu_ API key you hold stops working immediately, including " \
                             "keys on machines you no longer have. Nothing is deleted — your " \
                             "repositories, runs, intents, keys and memberships remain, with " \
                             "your name on them. This cannot be undone from within SpecGuard.")
    expect(panel).not_to include("agent key")
  end

  # SPGD-1934's post-close half: the notice names the cut live agent keys — the fact the
  # person is most likely to meet next, a CI job answering 401 under a key whose owner no
  # longer resolves — and counts the live half only, a revoked row with it.
  # @intent: { entity: "User", action: "name cut agent keys after closure", behavior: "POST /account/close with two live agent keys and one revoked redirects to root with the default closure notice plus a sentence naming 2 live agent keys stopped authenticating and never naming the revoked row's count", layer: "request" }
  it "names the live agent keys that stopped in the post-close notice" do
    alpha = create_repository(user: person, github_full_name: "acme/alpha")
    beta = create_repository(user: person, github_full_name: "acme/beta")
    gamma = create_repository(user: person, github_full_name: "acme/gamma")
    create_agent_api_key(user: person, repositories: [alpha, beta], name: "Fleet")
    create_agent_api_key(user: person, repositories: [gamma], name: "Scout")
    revoked = create_agent_api_key(user: person, repositories: [beta], name: "Retired")
    revoked.revoke!

    close_account

    expect(response.body).to include("Nothing of yours was deleted. Your 2 live agent keys " \
                                     "stopped authenticating when the account closed.")
    expect(response.body).not_to include("3 live agent keys")
  end

  # And the default: with no live agent keys the notice is the sentence it has always been —
  # including for a person whose keys are all personal, which the notice deliberately does not
  # quantify (the panel already told them; the root page names only the agent cut).
  # @intent: { entity: "User", action: "keep the default closure notice", behavior: "POST /account/close for an owner holding a live personal key but no agent keys answers the unchanged default closure notice with no agent-key sentence", layer: "request" }
  it "leaves the post-close notice unchanged when no agent keys are live" do
    create_user_api_key(user: person, name: "Laptop")

    close_account

    expect(response.body).to include("Your account is closed. You have been signed out, and " \
                                     "SpecGuard can no longer sign you in. Nothing of yours was deleted.")
    expect(response.body).not_to include("stopped authenticating when the account closed")
  end

  # SPGD-1947 — what closure does to the repositories the person OWNS. The owner holds no
  # membership row and every permission implicitly, so a repository nobody else can administer
  # becomes unopenable or unadministrable, and renaming (owner-only) is lost for all of them.
  context "when the person owns repositories" do
    def owned_item = response.body[response.body.index('id="account-closure-owned-repositories"')..]
                                  .split("</li>").first

    # @intent: { entity: "Repository", action: "disclose an unopenable owned repository", behavior: "GET /account for an owner of a repository with no members names it as unopenable in the Close-account panel with a link to its Members page and in the turbo_confirm, together with the owner-only rename sentence", layer: "request" }
    it "names an owned repository with no members as unopenable" do
      lonely = create_repository(user: person, github_full_name: "acme/lonely")

      get account_path

      item = owned_item
      expect(item).to include("You own 1 repository.")
      expect(item).to include("1 has no other members and will become unopenable")
      expect(item).to include(%(href="#{repository_members_path(lonely)}"))
      expect(item).to include("acme/lonely")
      expect(item).to include("Renaming a repository is owner-only")
      expect(item).not_to include("none who can manage")
      expect(closure_panel).to include("You own 1 repository. Of those, 1 has no other members " \
                                       "and will become unopenable (acme/lonely).")
      expect(closure_panel).to include("Renaming a repository is owner-only, so none of them can " \
                                       "be renamed once the account is closed.")
    end

    # @intent: { entity: "Repository", action: "disclose an unadministrable owned repository", behavior: "GET /account for an owner whose repository has only view and runs.ingest members names it as unadministrable, since no member can manage keys or members", layer: "request" }
    it "names an owned repository whose members cannot manage keys or members as unadministrable" do
      create_repository(user: person, github_full_name: "acme/stuck").tap do |repository|
        create_membership(repository: repository, user: colleague,
                          permissions: [RepositoryMembership::VIEW, RepositoryMembership::RUNS_INGEST])
      end

      get account_path

      item = owned_item
      expect(item).to include("1 has members but none who can manage keys or members, so its CI " \
                              "keys can no longer be minted or revoked from SpecGuard")
      expect(item).to include("acme/stuck")
      expect(item).not_to include("unopenable")
    end

    # @intent: { entity: "Repository", action: "stay quiet about an administrable owned repository", behavior: "GET /account for an owner whose repository has a keys.manage member (or a members.manage one) names no repository as unopenable or unadministrable, but still states the owner-only rename loss", layer: "request" }
    it "names no per-repository warning when a member can manage keys or members" do
      keys = create_repository(user: person, github_full_name: "acme/keys")
      create_membership(repository: keys, user: colleague,
                        permissions: [RepositoryMembership::KEYS_MANAGE])
      members = create_repository(user: person, github_full_name: "acme/people")
      create_membership(repository: members, user: colleague,
                        permissions: [RepositoryMembership::MEMBERS_MANAGE])

      get account_path

      item = owned_item
      expect(item).to include("You own 2 repositories.")
      expect(item).not_to include("unopenable")
      expect(item).not_to include("none who can manage")
      expect(item).not_to include("acme/keys")
      expect(item).to include("Renaming a repository is owner-only")
    end

    # @intent: { entity: "Repository", action: "cap the named repositories", behavior: "GET /account for an owner of more unopenable repositories than the name cap lists the first few full names and says 'and N more', in both the panel and the confirm", layer: "request" }
    it "caps the named repositories and counts the rest" do
      5.times { |n| create_repository(user: person, github_full_name: "acme/solo-#{n}") }

      get account_path

      expect(owned_item).to include("5 have no other members and will become unopenable")
      expect(owned_item).to include("and 2 more")
      expect(closure_panel).to include("acme/solo-0, acme/solo-1, acme/solo-2 and 2 more")
      expect(owned_item).not_to include("acme/solo-3")
    end

    # @intent: { entity: "Repository", action: "pair the panel and confirm copy", behavior: "GET /account renders the owned-repository disclosure in the turbo_confirm with the same clauses and names as the panel, in plain text", layer: "request" }
    it "says the same thing in the confirm dialog" do
      create_repository(user: person, github_full_name: "acme/lonely")

      get account_path

      expect(closure_panel).to include(
        "You own 1 repository. Of those, 1 has no other members and will become unopenable " \
        "(acme/lonely). Renaming a repository is owner-only, so none of them can be renamed " \
        "once the account is closed. Add a member holding keys.manage or members.manage first, " \
        "or remove the repository."
      )
    end

    # @intent: { entity: "Repository", action: "keep copy unchanged for a non-owner", behavior: "GET /account for a person who owns no repository (only a shared one) renders no owned-repository item and the unchanged 'three things' intro", layer: "request" }
    it "adds nothing for a person who owns no repository" do
      other = create_repository(user: colleague, github_full_name: "acme/theirs")
      create_membership(repository: other, user: person)

      get account_path

      panel = closure_panel
      expect(panel).not_to include("account-closure-owned-repositories")
      expect(panel).not_to include("You own")
      expect(panel).to include("Closing does three things, immediately:")
    end

    # @intent: { entity: "Repository", action: "disclose ownership after closure", behavior: "POST /account/close for an owner of repositories appends the owned count to the closure notice, stamps only archived_at and deletes nothing, while an owner of none keeps the default notice", layer: "request" }
    it "appends the owned count to the post-close notice and destroys nothing" do
      create_repository(user: person, github_full_name: "acme/one")
      create_repository(user: person, github_full_name: "acme/two")

      expect { close_account }.not_to change { Repository.count }

      expect(person.reload.archived_at).to be_present
      expect(response.body).to include("Nothing of yours was deleted. You still own 2 repositories")
    end

    # @intent: { entity: "User", action: "keep the default notice for a person owning nothing", behavior: "POST /account/close for a person owning no repository answers the unchanged default notice without an ownership sentence", layer: "request" }
    it "leaves the post-close notice unchanged for a person owning nothing" do
      close_account

      expect(response.body).to include("Nothing of yours was deleted.")
      expect(response.body).not_to include("still own")
    end
  end
end
