# frozen_string_literal: true

require "rails_helper"

# SPGD-808 — the connected-accounts list on `/account`, and the Disconnect beside each row.
#
# A `GithubInstallation` was written at the App callback and could be removed by nothing the person
# it belongs to could reach: `config/routes.rb` declared `create`, `authorize` and `callback` and no
# `destroy`, and the only satisfier was the `dependent: :destroy` cascade when the whole user row
# went. `User#github_installations` states the principle it was failing — "connecting GitHub is not
# the sort of act that should quietly become irreversible" — so this file is that sentence made
# falsifiable.
#
# Everything here goes through the real routes. Nothing calls `destroy` on a model directly: the
# claim under test is that a PERSON can do this from a page, and a spec that reached past the
# controller would pass just as happily against an app with no route at all.
RSpec.describe "Connected GitHub accounts on /account", type: :request do
  def disconnect(installation) = delete github_installation_disconnect_path(installation)

  # The page from the panel down. The sign-in helper leaves a "Connected acme." flash at the top of
  # the body, so an assertion about WHICH NAMES ARE IN THE LIST — and above all about their ORDER —
  # would otherwise be reading that banner and passing regardless of what the panel rendered.
  def installations_panel = response.body[response.body.index('id="github-installations"')..]

  def grant_for(user) = GithubRegistrationGrant.find_by(user_id: user.id)

  # The picker render, which is the ONLY place a grant is captured
  # (`GithubRepositoryListing#github_sources`, memoized and lazy). Named rather than inlined because
  # criterion 4 turns entirely on this render happening AFTER the disconnect.
  def visit_picker = get new_repository_path

  # SPGD-808 criterion 1 — the list itself, which is the half that existed nowhere.
  describe "the list" do
    it "names every installation the signed-in user holds, newest first" do
      person = sign_in_via_github(installation: 5001)
      add_github_installation(person, installation_id: 6002, account_login: "globex")

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Connected GitHub accounts")
      panel = installations_panel
      expect(panel).to include("acme").and include("globex")
      # `recent_first` — the scope whose own comment already claimed this list as its reason to
      # exist. Asserted as an ORDER rather than as two `include`s, which the line above already has.
      expect(panel.index("globex")).to be < panel.index("acme")
    end

    # A row recorded from a callback that carried no login. `display_name` falls back to the id, and
    # the cell must not come out blank — an unnameable row is one a reader cannot decide about.
    it "falls back to the installation id when GitHub reported no account login" do
      person = sign_in_via_github(installation: false)
      add_github_installation(person, installation_id: 7003, account_login: nil)

      get account_path

      expect(response.body).to include("Installation 7003")
    end

    it "renders an empty state, and an offer to connect, when there are none" do
      sign_in_via_github(installation: false)
      # The offer is a real Connect button rather than the unconfigured notice `github_install_button`
      # falls back to — the suite has no App credentials, which is the whole reason `configured?`
      # exists, so a spec about the button says so.
      allow(SpecGuard::GithubApp).to receive(:configured?).and_return(true)

      get account_path

      expect(installations_panel).to include("No connected GitHub accounts")
      expect(installations_panel).to include('action="/github/installation')
    end

    # NON-NEGOTIABLE (c). The fear this panel has to answer before a reader presses anything: a
    # Disconnect that killed their pipelines would be found out by them and not by us. It cannot —
    # ingest authenticates on the repository's own `sgk_` key — and the panel has to SAY so, which
    # is a claim about the rendered sentence rather than about the mechanism criterion 5 measures.
    it "tells the reader on the page that registered repositories are unaffected" do
      sign_in_via_github

      get account_path

      expect(response.body).to include("does not affect repositories you have already registered")
    end

    # NON-NEGOTIABLE (b). The dialog carries the one fact a reader would otherwise get wrong in the
    # dangerous direction — believing they had revoked SpecGuard's access at the source — and the
    # one that makes this safe to press: the App being still installed means Connect brings it back.
    it "warns in the confirm dialog that this is not an uninstall on GitHub, and is recoverable" do
      sign_in_via_github

      get account_path

      expect(response.body).to include("does NOT uninstall the SpecGuard App on GitHub")
      expect(response.body).to include("connecting again brings this back")
    end
  end

  # SPGD-808 criterion 2 — the id is a path segment a person can type, so the scoping is the whole
  # of the authorization.
  describe "another person's installation id" do
    it "removes nothing and does not fail" do
      stranger = create_user(github_uid: "9009", github_handle: "mallory", installation_id: 8004)
      theirs = stranger.github_installations.sole
      sign_in_via_github

      expect { disconnect(theirs) }.not_to change { stranger.github_installations.count }.from(1)

      expect(response).to redirect_to(account_path)
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    # The miss is reported as the same outcome an already-deleted row gets. A distinct sentence for
    # "that one exists but is not yours" would confirm to somebody walking ids that it does.
    it "says the same thing it says about an id that never existed" do
      stranger = create_user(github_uid: "9009", github_handle: "mallory", installation_id: 8004)
      sign_in_via_github

      disconnect(stranger.github_installations.sole)
      theirs = flash[:notice]

      disconnect(GithubInstallation.maximum(:id) + 1)

      expect(flash[:notice]).to eq(theirs)
    end
  end

  # SPGD-808 criterion 3 — the dead row's TWO costs, which are the reason this is worth doing beyond
  # tidiness: a permanent warning whose stated remedy points back where the reader came from, and a
  # live GitHub page-walk on every picker render, forever, to return nothing.
  describe "disconnecting an account GitHub no longer answers for" do
    # Two installations, one of which 404s — `InstallationRepositories` reads that as `:unreadable`,
    # which is exactly what uninstalling the App on GitHub (the thing the disclosure invites) leaves
    # behind. Per-installation rather than one fake, because the whole point is that they differ.
    def stub_one_dead_account
      live = FakeGithubApi.new(repos: [github_repo("acme/billing-service")])
      dead = FakeGithubApi.new(not_found: true)
      stub_github_per_installation { |id| id == 6002 ? dead : live }
      [live, dead]
    end

    before do
      @person = sign_in_via_github(installation: 5001)
      add_github_installation(@person, installation_id: 6002, account_login: "globex")
      @live, @dead = stub_one_dead_account
    end

    it "removes the warning from the registration picker" do
      visit_picker
      expect(response.body).to include("GitHub no longer lists globex")

      disconnect(@person.github_installations.find_by!(installation_id: 6002))
      visit_picker

      expect(response.body).not_to include("GitHub no longer lists globex")
      expect(response.body).not_to include("could not be read")
    end

    it "removes it from the bulk picker too" do
      get bulk_repositories_path
      expect(response.body).to include("GitHub no longer lists globex")

      disconnect(@person.github_installations.find_by!(installation_id: 6002))
      get bulk_repositories_path

      expect(response.body).not_to include("GitHub no longer lists globex")
    end

    # The cost half, measured rather than argued. `collect` walks `client.repositories` once per
    # installation, so the dead row buys a GitHub round trip per render to raise `NotFound`.
    it "drops one GitHub call from every later picker render" do
      visit_picker
      before_count = @dead.calls_to(:repositories) + @live.calls_to(:repositories)

      disconnect(@person.github_installations.find_by!(installation_id: 6002))

      @live, @dead = stub_one_dead_account
      visit_picker
      after_count = @dead.calls_to(:repositories) + @live.calls_to(:repositories)

      expect(before_count).to eq(2)
      expect(after_count).to eq(1)
      # And the call that is gone is the one to the account that no longer answers, not an
      # arbitrary one: the live installation is still read.
      expect(@dead.calls_to(:repositories)).to eq(0)
      expect(@live.calls_to(:repositories)).to eq(1)
    end
  end

  # SPGD-808 criterion 4 and NON-NEGOTIABLE (a) — the mirrored invariant, and the highest-risk part
  # of this slice.
  #
  # `GithubRegistrationGrant.capture` gates on `sources.complete?` ALONE, and with no installations
  # `InstallationRepositories.sources` answers `blank_sources(installed: false)` — `truncated: false,
  # error: nil` — which IS complete. So a picker render after the last disconnect would overwrite the
  # grant with empty arrays and a FRESH stamp, and a fresh-but-empty grant falls past `registrable?`
  # and `visible?` onto `:not_in_installation`: "Add it on GitHub, then pick it here", said to
  # somebody whose repository is already there. Deleting the grant lands them on `:not_granted`,
  # which is true and names the real fix.
  describe "disconnecting the LAST installation" do
    before do
      @person = sign_in_via_github(installation: 5001)
      visit_picker # mints a real grant through the only path that mints one
      expect(grant_for(@person)).to be_present
    end

    it "leaves no grant behind" do
      disconnect(@person.github_installations.sole)

      expect(grant_for(@person)).to be_nil
    end

    # THE TIMING, which is what makes this a real risk rather than a theoretical one. `capture` is
    # reached only from a picker render, and `/account` renders no picker — so the redirect after
    # `destroy` cannot forge the empty grant, and the example above would pass even if the
    # controller did nothing. The forging happens on the reader's NEXT visit to a picker, which is
    # what this renders before asserting.
    it "still leaves no grant after the reader visits a picker again" do
      disconnect(@person.github_installations.sole)

      visit_picker
      expect(response).to have_http_status(:ok)

      expect(grant_for(@person)).to be_nil
    end

    it "still leaves none after the bulk picker, which captures on the same read" do
      disconnect(@person.github_installations.sole)

      get bulk_repositories_path

      expect(grant_for(@person)).to be_nil
    end

    # The consequence the whole invariant exists for, asserted end to end at the endpoint that
    # redeems a grant. Read from `InstallationRepositories::MESSAGES` rather than quoted, so this
    # pins WHICH VERDICT is reached and cannot drift from the wording the app ships.
    it "makes the API say SpecGuard has no record, not that the repository is missing from GitHub" do
      key = create_user_api_key(user: @person)
      disconnect(@person.github_installations.sole)
      visit_picker

      post "/api/v1/repositories", params: { github_full_name: "acme/billing-service" }, as: :json,
                                   headers: { "Authorization" => "Bearer #{key.raw_token}" }

      expect(response.body).to include(InstallationRepositories::MESSAGES[:not_granted])
      expect(response.body).not_to include(InstallationRepositories::MESSAGES[:not_in_installation])
    end
  end

  # The other side of the guard: a grant that can still be redeemed must not be thrown away while an
  # installation remains, or an agent holding a key that worked a moment ago stops being able to
  # register for a reason nobody told it.
  describe "disconnecting one of several installations" do
    it "keeps the grant" do
      person = sign_in_via_github(installation: 5001)
      add_github_installation(person, installation_id: 6002, account_login: "globex")
      visit_picker
      expect(grant_for(person)).to be_present

      disconnect(person.github_installations.find_by!(installation_id: 6002))

      expect(grant_for(person)).to be_present
      expect(person.github_installations.count).to eq(1)
    end
  end

  # SPGD-808 criterion 5 — the promise the panel makes in prose, measured. Nothing outside this table
  # references an installation (the sole FK is `github_installations` → `users`) and ingest reads
  # GitHub not at all, so this is a claim that can be demonstrated rather than reasoned about.
  describe "a repository registered before the disconnect" do
    it "still resolves and still ingests on its own sgk_ key" do
      person = sign_in_via_github(installation: 5001)
      repository = create_repository(user: person, github_full_name: "acme/billing-service")
      key = repository.api_keys.create!(name: "CI")

      disconnect(person.github_installations.sole)

      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{key.raw_token}" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("repository", "full_name")).to eq("acme/billing-service")

      expect {
        post "/api/v1/ingest", params: ingest_payload.to_json,
                               headers: { "Content-Type" => "application/json",
                                          "Authorization" => "Bearer #{key.raw_token}" }
      }.to change { repository.test_runs.count }.by(1)
      expect(response).to have_http_status(:accepted)
    end

    it "still has its page" do
      person = sign_in_via_github(installation: 5001)
      repository = create_repository(user: person, github_full_name: "acme/billing-service")

      disconnect(person.github_installations.sole)

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/billing-service")
    end
  end

  # SPGD-808 criterion 6 — what makes this a reversible gesture rather than one to hesitate over,
  # and the fact the confirm dialog asserts. Driven through the real callback, because "Connect
  # again" is that flow and nothing else.
  describe "reconnecting afterwards" do
    it "re-records the row and puts it back on the list" do
      person = sign_in_via_github(installation: 5001)
      disconnect(person.github_installations.sole)

      get account_path
      expect(response.body).to include("No connected GitHub accounts")

      authorize_github_app(installations: [[5001, "acme"]])

      get account_path
      expect(response.body).not_to include("No connected GitHub accounts")
      expect(response.body).to include("acme")
      expect(person.github_installations.reload.pluck(:installation_id)).to eq([5001])
    end
  end

  # The action talks to GitHub not at all, so it must keep working on an instance whose App
  # credentials have been removed — which is precisely the reader left holding rows they can no
  # longer act on. `require_configured_app` guards the three actions that go to github.com and must
  # not guard this one.
  it "disconnects even when the GitHub App is not configured on this instance" do
    person = sign_in_via_github(installation: 5001)
    allow(SpecGuard::GithubApp).to receive(:configured?).and_return(false)

    expect { disconnect(person.github_installations.sole) }
      .to change { person.github_installations.count }.from(1).to(0)

    expect(response).to redirect_to(account_path)
  end

  it "refuses a signed-out visitor" do
    person = create_user(github_uid: "9009", github_handle: "octocat", installation_id: 5001)

    expect { disconnect(person.github_installations.sole) }
      .not_to change { person.github_installations.count }.from(1)

    expect(response).not_to have_http_status(:ok)
  end
end
