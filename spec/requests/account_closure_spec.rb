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
  # The colleague whose rows and access must survive the person's closure untouched — passed a
  # distinct uid, since the signed-in person IS uid 1001 and uid is unique.
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
end
