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
    # @intent: {"entity": "GithubInstallation", "action": "list installations newest first", "behavior": "GET /account returns ok with a Connected GitHub accounts panel listing both acme and globex, globex appearing before acme", "layer": "request"}
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
    # @intent: {"entity": "GithubInstallation", "action": "fall back to installation id", "behavior": "an installation recorded with no account login renders as Installation 7003 rather than a blank cell", "layer": "request"}
    it "falls back to the installation id when GitHub reported no account login" do
      person = sign_in_via_github(installation: false)
      add_github_installation(person, installation_id: 7003, account_login: nil)

      get account_path

      expect(response.body).to include("Installation 7003")
    end

    # @intent: {"entity": "GithubInstallation", "action": "render empty state with offer", "behavior": "with no installations the panel reads No connected GitHub accounts and renders a connect form posting to /github/installation", "layer": "request"}
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
    # @intent: {"entity": "GithubInstallation", "action": "promise repositories unaffected", "behavior": "the page states on the panel that disconnecting does not affect repositories you have already registered", "layer": "request"}
    it "tells the reader on the page that registered repositories are unaffected" do
      sign_in_via_github

      get account_path

      expect(response.body).to include("does not affect repositories you have already registered")
    end

    # NON-NEGOTIABLE (b). The dialog carries the one fact a reader would otherwise get wrong in the
    # dangerous direction — believing they had revoked SpecGuard's access at the source — and the
    # one that makes this safe to press: the App being still installed means Connect brings it back.
    # @intent: {"entity": "GithubInstallation", "action": "warn dialog is recoverable", "behavior": "the confirm dialog copy says it does NOT uninstall the SpecGuard App on GitHub and that connecting again brings this back", "layer": "request"}
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
    # @intent: {"entity": "GithubInstallation", "action": "ignore another's installation id", "behavior": "deleting another person's installation leaves their count at 1 and redirects back to /account, which renders ok after following the redirect", "layer": "request"}
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
    # @intent: {"entity": "GithubInstallation", "action": "match not-found wording", "behavior": "the flash notice after disconnecting a stranger's installation is byte-identical to the one for an id that never existed, so walking ids confirms nothing", "layer": "request"}
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

    # @intent: {"entity": "GithubInstallation", "action": "remove picker warning", "behavior": "after disconnecting the dead globex account the new-repository picker no longer shows GitHub no longer lists globex nor any could not be read text", "layer": "request"}
    it "removes the warning from the registration picker" do
      visit_picker
      expect(response.body).to include("GitHub no longer lists globex")

      disconnect(@person.github_installations.find_by!(installation_id: 6002))
      visit_picker

      expect(response.body).not_to include("GitHub no longer lists globex")
      expect(response.body).not_to include("could not be read")
    end

    # @intent: {"entity": "GithubInstallation", "action": "clear bulk picker warning", "behavior": "the bulk repositories picker stops showing GitHub no longer lists globex once the dead installation is disconnected", "layer": "request"}
    it "removes it from the bulk picker too" do
      get bulk_repositories_path
      expect(response.body).to include("GitHub no longer lists globex")

      disconnect(@person.github_installations.find_by!(installation_id: 6002))
      get bulk_repositories_path

      expect(response.body).not_to include("GitHub no longer lists globex")
    end

    # The cost half, measured rather than argued. `collect` walks `client.repositories` once per
    # installation, so the dead row buys a GitHub round trip per render to raise `NotFound`.
    # @intent: {"entity": "GithubInstallation", "action": "drop dead GitHub call", "behavior": "picker renders go from two repositories calls to one after the disconnect, the remaining call being to the live installation and zero to the dead one", "layer": "request"}
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
  # `GithubRegistrationGrant.capture` refuses a reading that is not GitHub's whole answer — not
  # `complete?`, not a person holding no installation rows (`installed?`: with no installations
  # `InstallationRepositories.sources` answers `blank_sources(installed: false)`, which IS complete),
  # and — since SPGD-975 — not one where no installation answered — so no render after the last
  # disconnect mints anything. That is exactly why the deletion below is what lands this person on
  # `:not_granted`: a still-fresh grant of theirs would otherwise keep REDEEMING until `MAX_AGE`,
  # and `:not_granted` — which is true and names the real fix — is reachable no other way.
  describe "disconnecting the LAST installation" do
    before do
      @person = sign_in_via_github(installation: 5001)
      visit_picker # mints a real grant through the only path that mints one
      expect(grant_for(@person)).to be_present
    end

    # @intent: {"entity": "GithubInstallation", "action": "delete grant with last installation", "behavior": "disconnecting the only installation leaves the person's GithubRegistrationGrant record gone", "layer": "request"}
    it "leaves no grant behind" do
      disconnect(@person.github_installations.sole)

      expect(grant_for(@person)).to be_nil
    end

    # THE TIMING, which is what makes this a real risk rather than a theoretical one. `capture` is
    # reached only from a picker render, and `/account` renders no picker — so the destroy request
    # itself mints nothing, and the example above isolates the deletion. A regression of the
    # model's gates would surface as a fresh empty grant minted on the reader's NEXT visit to a
    # picker — the only path that reaches `capture` — which is what this renders before asserting.
    # @intent: {"entity": "GithubInstallation", "action": "withstand later picker visit", "behavior": "after the last disconnect a further picker render returns ok and still mints no fresh empty grant", "layer": "request"}
    it "still leaves no grant after the reader visits a picker again" do
      disconnect(@person.github_installations.sole)

      visit_picker
      expect(response).to have_http_status(:ok)

      expect(grant_for(@person)).to be_nil
    end

    # @intent: {"entity": "GithubInstallation", "action": "withstand bulk picker visit", "behavior": "a bulk picker render after the last disconnect, which captures on the same read, also leaves no grant behind", "layer": "request"}
    it "still leaves none after the bulk picker, which captures on the same read" do
      disconnect(@person.github_installations.sole)

      get bulk_repositories_path

      expect(grant_for(@person)).to be_nil
    end

    # The consequence the whole invariant exists for, asserted end to end at the endpoint that
    # redeems a grant. Read from `InstallationRepositories::MESSAGES` rather than quoted, so this
    # pins WHICH VERDICT is reached and cannot drift from the wording the app ships.
    # @intent: {"entity": "GithubInstallation", "action": "answer not_granted at API", "behavior": "registering after the last disconnect answers with the not_granted message \u2014 SpecGuard has no record of the GitHub installation \u2014 and never the not_in_installation claim that the repository is missing from GitHub", "layer": "request"}
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
    # @intent: {"entity": "GithubInstallation", "action": "keep grant with installations left", "behavior": "disconnecting one of two installations keeps the grant present and the remaining installation count at 1", "layer": "request"}
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
    # @intent: {"entity": "GithubInstallation", "action": "preserve ingest path", "behavior": "a repository registered before the disconnect still resolves on its own sgk_ key with ok and full_name acme/billing-service, and a POST to the ingest endpoint is answered 202 and creates exactly one test run", "layer": "request"}
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

    # @intent: {"entity": "GithubInstallation", "action": "preserve repository page", "behavior": "the registered repository's page still returns ok and names acme/billing-service after the disconnect", "layer": "request"}
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
    # @intent: {"entity": "GithubInstallation", "action": "restore row on reconnect", "behavior": "going through the real App callback after a disconnect re-records installation 5001, so the list shows acme again with no empty state and the row's installation_id is 5001", "layer": "request"}
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

  # SPGD-986 — the panel NAMES an account GitHub no longer answers for, so the false
  # `:not_in_installation` a fresh-but-empty grant keeps answering has a local fix instead of a
  # `MAX_AGE` wait. The reading is `InstallationReachability`: credential-gated, one walk per person
  # per hour, cached between walks, and silent whenever it could not be made.
  describe "an account GitHub no longer answers for" do
    # `config/environments/test.rb` runs `:null_store`, which would make every throttle example pass
    # or fail for reasons unrelated to the code. A real store, shared across the example's requests.
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    include ActiveSupport::Testing::TimeHelpers

    before { allow(Rails).to receive(:cache).and_return(cache) }

    def stub_one_dead_account
      live = FakeGithubApi.new(repos: [github_repo("acme/billing-service")])
      dead = FakeGithubApi.new(not_found: true)
      stub_github_per_installation { |id| id == 6002 ? dead : live }
      [live, dead]
    end

    # The session credential outlives the throttle hour here, so a render AFTER the hour still has
    # a token to walk with — the default helper token expires in an hour, which would make the
    # "walks again" examples pass for the wrong reason.
    def two_account_person
      person = sign_in_via_github(installation: 5001)
      authorize_github_app(installations: [[5001, "acme"], [6002, "globex"]], expires_at: 1.day.from_now)
      person
    end

    # The row for one account, sliced out of the panel so an assertion about globex cannot be
    # satisfied by acme's cell.
    def row_for(name) = installations_panel.split("<tr").find { |chunk| chunk.include?(">#{name}") || chunk.include?("#{name}\n") }

    # The red this ticket pins first: before the change both rows were presented identically.
    # @intent: {"entity": "GithubInstallation", "action": "name an unreachable account", "behavior": "an installation GitHub answers 404 for is marked No longer reachable on its own row, attributed to its own account, and the live account's row is not", "layer": "request"}
    it "names the dead account on its own row and not the live one" do
      two_account_person
      stub_one_dead_account

      get account_path

      globex = row_for("globex")
      acme = row_for("acme")
      expect(globex).to include("No longer reachable").and include('data-installation-state="unreachable"')
      expect(globex).to include("GitHub no longer answers for")
      expect(acme).to include('data-installation-state="listed"')
      expect(acme).not_to include("No longer reachable")
    end

    # A false positive here tells somebody to sever a working connection.
    # @intent: {"entity": "GithubInstallation", "action": "leave live accounts unmarked", "behavior": "when every installation answers, the panel marks nothing as unreachable", "layer": "request"}
    it "marks nothing when every installation answers" do
      two_account_person
      stub_github(repos: [github_repo("acme/billing-service")])

      get account_path

      expect(installations_panel).not_to include("No longer reachable")
      expect(installations_panel).not_to include("data-installation-state=\"unreachable\"")
    end

    # @intent: {"entity": "GithubInstallation", "action": "stay silent without a credential", "behavior": "a session holding no GitHub credential makes no GitHub call and renders the panel with no marks", "layer": "request"}
    it "says nothing, and asks GitHub nothing, when the session holds no credential" do
      person = sign_in_via_github(installation: 5001, authorize: false)
      add_github_installation(person, installation_id: 6002, account_login: "globex")
      _live, dead = stub_one_dead_account

      get account_path

      expect(response).to have_http_status(:ok)
      expect(installations_panel).not_to include("No longer reachable")
      expect(dead.calls_to(:repositories)).to eq(0)
    end

    # @intent: {"entity": "GithubInstallation", "action": "stay silent on error", "behavior": "when GitHub is unavailable the panel renders exactly as before, with no marks and a 200", "layer": "request"}
    it "says nothing when the reading fails" do
      two_account_person
      stub_github(unavailable: true)

      get account_path

      expect(response).to have_http_status(:ok)
      expect(installations_panel).not_to include("No longer reachable")
    end

    # @intent: {"entity": "GithubInstallation", "action": "keep cached answer through a failing walk", "behavior": "after a successful walk is cached, a walk that fails still renders the cached mark", "layer": "request"}
    it "renders the cached answer when a later walk fails" do
      two_account_person
      stub_one_dead_account
      get account_path
      expect(installations_panel).to include("No longer reachable")

      travel_to((InstallationReachability::FRESH_FOR + 1.minute).from_now) do
        stub_github(unavailable: true)
        get account_path
      end

      expect(installations_panel).to include("No longer reachable")
    end

    # SPGD-986 criterion 10. The bound is stubbed in its own example, with the unstubbed positive
    # partner directly below, so moving the constant is a visible test change.
    describe "the one-walk-an-hour throttle" do
      # @intent: {"entity": "GithubInstallation", "action": "throttle the walk", "behavior": "a second render within the hour issues no GitHub call and renders the identical panel", "layer": "request"}
      it "issues no GitHub call on a second render within the hour, and renders the same panel" do
        two_account_person
        live, dead = stub_one_dead_account

        get account_path
        first = installations_panel
        calls = live.calls_to(:repositories) + dead.calls_to(:repositories)
        expect(calls).to eq(2)

        travel_to(30.minutes.from_now) { get account_path }

        expect(live.calls_to(:repositories) + dead.calls_to(:repositories)).to eq(calls)
        # The "Connected N minutes ago" cell legitimately moves with the clock; everything else the
        # reading decides — which rows are marked — must not.
        marks = ->(html) { html.scan(/data-installation-state="\w+"/) }
        expect(marks.call(installations_panel)).to eq(marks.call(first))
        expect(installations_panel).to include("No longer reachable")
      end

      # @intent: {"entity": "GithubInstallation", "action": "walk again after the hour", "behavior": "once the hour has lapsed the next render walks GitHub again", "layer": "request"}
      it "walks again once the hour has lapsed" do
        two_account_person
        live, dead = stub_one_dead_account
        get account_path

        travel_to((InstallationReachability::FRESH_FOR + 1.minute).from_now) { get account_path }

        expect(live.calls_to(:repositories) + dead.calls_to(:repositories)).to eq(4)
      end

      # The throttle bounds the ATTEMPT, not only the success: a failing GitHub must not turn every
      # render into the per-render walk this throttle exists to refuse.
      # @intent: {"entity": "GithubInstallation", "action": "throttle a failing walk", "behavior": "when GitHub fails, a second render within the hour issues no GitHub call, and the hour's lapse walks again", "layer": "request"}
      it "issues no GitHub call on a second render within the hour when the first walk failed" do
        two_account_person
        failing = FakeGithubApi.new(unavailable: true)
        stub_github_per_installation { |_id| failing }

        get account_path
        calls = failing.calls_to(:repositories)
        expect(calls).to be >= 1

        travel_to(30.minutes.from_now) { get account_path }

        expect(failing.calls_to(:repositories)).to eq(calls)
        expect(installations_panel).not_to include("No longer reachable")

        # The unstubbed positive partner: the hour lapsing re-opens the walk.
        travel_to((InstallationReachability::FRESH_FOR + 1.minute).from_now) { get account_path }
        expect(failing.calls_to(:repositories)).to be > calls
      end

      # @intent: {"entity": "GithubInstallation", "action": "throttle a failing walk after a clean one", "behavior": "a failed walk after a cached clean one is throttled and still renders the cached mark", "layer": "request"}
      it "does not re-walk within the hour after a failed walk, and keeps rendering the last clean answer" do
        two_account_person
        stub_one_dead_account
        get account_path

        failing = FakeGithubApi.new(unavailable: true)
        stub_github_per_installation { |_id| failing }
        travel_to((InstallationReachability::FRESH_FOR + 1.minute).from_now) { get account_path }
        calls = failing.calls_to(:repositories)
        expect(calls).to be >= 1

        travel_to((InstallationReachability::FRESH_FOR + 11.minutes).from_now) { get account_path }

        expect(failing.calls_to(:repositories)).to eq(calls)
        expect(installations_panel).to include("No longer reachable")
      end

      # @intent: {"entity": "GithubInstallation", "action": "pin the bound", "behavior": "the throttle bound is exactly one hour", "layer": "request"}
      it "is one hour" do
        expect(InstallationReachability::FRESH_FOR).to eq(1.hour)
      end
    end

    # @intent: {"entity": "GithubInstallation", "action": "drop the cached reading on reconnect", "behavior": "passing back through the App callback discards the cached reading so a reconnected account is not still named as gone", "layer": "request"}
    it "drops the cached reading when the person passes back through the App callback" do
      two_account_person
      stub_one_dead_account
      get account_path
      expect(installations_panel).to include("No longer reachable")

      stub_github(repos: [github_repo("acme/billing-service")])
      authorize_github_app(installations: [[5001, "acme"], [6002, "globex"]], expires_at: 1.day.from_now)
      get account_path

      expect(installations_panel).not_to include("No longer reachable")
    end

    # The landmine: the panel is a READ and must never become a `GithubRegistrationGrant.capture`.
    # @intent: {"entity": "GithubRegistrationGrant", "action": "never capture from /account", "behavior": "rendering /account with a credential walks GitHub and mints no grant", "layer": "request"}
    it "is not a grant-capture site" do
      person = two_account_person
      stub_github(repos: [github_repo("acme/billing-service")])
      expect(grant_for(person)).to be_nil

      get account_path

      expect(grant_for(person)).to be_nil
    end

    # Decision B: the panel states, it does not destroy.
    # @intent: {"entity": "GithubInstallation", "action": "never destroy on read", "behavior": "naming a dead account removes neither its row nor an existing grant", "layer": "request"}
    it "destroys nothing" do
      person = two_account_person
      stub_github(repos: [github_repo("acme/billing-service")])
      visit_picker
      stub_one_dead_account
      grant = grant_for(person)
      expect(grant).to be_present

      expect { get account_path }.not_to change { [person.github_installations.count, grant_for(person)&.id] }

      expect(installations_panel).to include("No longer reachable")
    end

    # SPGD-986 criterion 6, scoped to the SOLE-installation case on purpose:
    # `forget_registration_grant_if_last_installation` is guarded on the last row, so disconnecting
    # one dead account of two correctly leaves a redeemable grant standing.
    # @intent: {"entity": "GithubRegistrationGrant", "action": "reach not_granted through the panel", "behavior": "a sole-installation user holding a fresh grant whose installation 404s sees the account named, presses Disconnect, and the API then answers not_granted rather than not_in_installation", "layer": "request"}
    it "lets a sole-installation user reach :not_granted through the panel's own Disconnect" do
      person = sign_in_via_github(installation: 5001)
      key = create_user_api_key(user: person)
      visit_picker # mints the grant while the installation still answers
      expect(grant_for(person)).to be_present
      stub_github(not_found: true)

      post "/api/v1/repositories", params: { github_full_name: "acme/billing-service" }, as: :json,
                                   headers: { "Authorization" => "Bearer #{key.raw_token}" }
      expect(response.body).to include(InstallationRepositories::MESSAGES[:not_in_installation])

      get account_path
      expect(installations_panel).to include("No longer reachable")

      disconnect(person.github_installations.sole)

      post "/api/v1/repositories", params: { github_full_name: "acme/billing-service" }, as: :json,
                                   headers: { "Authorization" => "Bearer #{key.raw_token}" }
      expect(response.body).to include(InstallationRepositories::MESSAGES[:not_granted])
      expect(response.body).not_to include(InstallationRepositories::MESSAGES[:not_in_installation])
    end
  end

  # The action talks to GitHub not at all, so it must keep working on an instance whose App
  # credentials have been removed — which is precisely the reader left holding rows they can no
  # longer act on. `require_configured_app` guards the three actions that go to github.com and must
  # not guard this one.
  # @intent: {"entity": "GithubInstallation", "action": "work unconfigured", "behavior": "with SpecGuard::GithubApp configured? stubbed false the disconnect still removes the installation from 1 to 0 and redirects to /account", "layer": "request"}
  it "disconnects even when the GitHub App is not configured on this instance" do
    person = sign_in_via_github(installation: 5001)
    allow(SpecGuard::GithubApp).to receive(:configured?).and_return(false)

    expect { disconnect(person.github_installations.sole) }
      .to change { person.github_installations.count }.from(1).to(0)

    expect(response).to redirect_to(account_path)
  end

  # @intent: {"entity": "GithubInstallation", "action": "refuse signed-out visitor", "behavior": "a signed-out visitor's disconnect leaves the installation count unchanged at 1 and the response is not ok", "layer": "request"}
  it "refuses a signed-out visitor" do
    person = create_user(github_uid: "9009", github_handle: "octocat", installation_id: 5001)

    expect { disconnect(person.github_installations.sole) }
      .not_to change { person.github_installations.count }.from(1)

    expect(response).not_to have_http_status(:ok)
  end
end
