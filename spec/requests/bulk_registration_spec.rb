# frozen_string_literal: true

require "rails_helper"

# Bulk registration, end to end: choosing an organization, choosing its repositories, and the
# summary that has to add up.
#
# The interesting examples here are the ones about what the PAGE is responsible for versus what the
# SERVER is responsible for. The page must not offer a click that can only fail — an already
# registered repository, an organization with nothing in it — and the server must not believe
# anything the page says, because the tick boxes are client-controlled and a POST does not have to
# come from the form at all.
#
# Both halves are built from one set: the repositories the SpecGuard GitHub App is installed on for
# this user. That is what the picker offers and what registration verifies against, so
# `stub_github(repos: […])` decides both, and a name outside it is refused however it was submitted.
RSpec.describe "Bulk organization registration", type: :request do
  before { @user = sign_in_via_github }

  def choose_organization(login) = get bulk_repositories_path(organization: login)

  def submit(names, organization: "acme")
    post bulk_repositories_path, params: { organization: organization, github_full_names: names }
  end

  describe "GET /repositories/bulk — choosing an organization" do
    it "lists the organizations the App is installed on something in, with counts" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"),
                          github_repo("beta/thing")])

      get bulk_repositories_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme")
      expect(response.body).to include("beta")
      expect(response.body).to include("2 repositories")
    end

    # An organization with nothing in the installation cannot appear here, because it contributes no
    # repositories to group — the chooser is the installation, sliced by owner. There is no
    # "withheld" set to explain any more: the OAuth listing returned every repository the user could
    # see and had to account for the ones they could not register, where an installation contains
    # only what somebody who administers those repositories deliberately handed over.
    it "does not offer an organization the App is not installed on anything in" do
      stub_github(repos: [github_repo("acme/api")])

      get bulk_repositories_path

      expect(response.body).to include("acme")
      expect(response.body).not_to include("readonly")
    end

    # SPGD-818 reversed this. It used to read "does not offer the user's own repositories as an
    # organization" — the filter that was the whole of the bug. A personal namespace is now a card
    # like any other, and it carries a marker so the page still says which kind it is.
    it "offers the user's own namespace alongside the organizations, marked as personal" do
      stub_github(repos: [github_repo("acme/api"),
                          github_repo("octocat/dotfiles", owner_type: "User")])

      get bulk_repositories_path

      expect(response.body).to include("acme")
      expect(response.body).to include("octocat")
      expect(response.body).to include(bulk_repositories_path(organization: "octocat"))
      expect(response.body).to include("Personal")
    end

    # Criterion 1, end to end at this layer: the listing the ticket opens with — twenty repositories
    # in one personal namespace and not an organization in sight — used to render the "not for you"
    # empty state. It now renders a chooser.
    it "offers a chooser for a listing that is entirely personal" do
      stub_github(repos: [github_repo("octocat/api", owner_type: "User"),
                          github_repo("octocat/blog", owner_type: "User")])

      get bulk_repositories_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("octocat")
      expect(response.body).to include("2 repositories")
      expect(response.body).not_to include("No repositories to register in a batch")
    end

    # Criterion 8's other half: the empty state is now reachable ONLY when the viewer administers
    # nothing anywhere. A personal-only listing is no longer one of its causes.
    it "says so plainly only when there is nothing at all to register" do
      stub_github(repos: [github_repo("acme/api", admin: false),
                          github_repo("octocat/theirs", owner_type: "User", admin: false)])

      get bulk_repositories_path

      expect(response.body).to include("No repositories to register in a batch")
      expect(response.body).not_to include("registered one at a time")
    end

    # The card's badge counts what the reader may act on, and the sentence under it accounts for the
    # rest. Per card rather than per page, because the answer differs for every organization: `acme`
    # is mostly theirs and `beta` is mostly not.
    it "counts what each organization offers, and says what it is holding back" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/legacy", admin: false),
                          github_repo("acme/vault", admin: false), github_repo("beta/thing")])

      get bulk_repositories_path

      expect(response.body).to include("1 repository")
      expect(response.body).to include("2 connected repositories you do not administer are not listed.")
    end

    # An organization the viewer administers nothing in is the one thing that is hidden rather than
    # counted — there is no card to hang a count on, and a card leading to an empty picker is worse
    # than no card.
    it "leaves out an organization the viewer administers nothing in" do
      stub_github(repos: [github_repo("acme/api"), github_repo("beta/thing", admin: false)])

      get bulk_repositories_path

      expect(response.body).to include("acme")
      expect(response.body).not_to include("/repositories/bulk?organization=beta")
    end

    # The listing cap is GLOBAL, so truncation can hide a whole account rather than some of one
    # account's repositories — a different and worse failure than a short list.
    it "says the account list may be incomplete when GitHub's listing was truncated" do
      stub_github(repos: [github_repo("acme/api")], truncated: true)

      get bulk_repositories_path

      expect(response.body).to include("missing an account")
    end

    # The other way a whole account goes missing: the installation it is connected through would
    # not answer. This page and the single-repository picker say it through ONE definition
    # (`GithubHelper#unreadable_accounts_sentence`), so the account is named identically on both and
    # only the noun differs — ACCOUNTS here, because that is what is missing from this list.
    #
    # This pinned "Organizations" until the chooser started offering personal namespaces, and the
    # noun was accurate while it filtered to organizations. It is not any more: a viewer whose
    # chooser holds only their own namespace would be told ORGANIZATIONS are missing from it. The
    # assertion moves with the noun rather than being deleted, so the reversal is on record.
    it "names the installation that could not be read" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [github_repo("acme/api")] }))
      end

      get bulk_repositories_path

      expect(response.body).to include("This list may be incomplete")
      expect(response.body).to include("SpecGuard could not read globex just now.")
      expect(response.body).to include("Accounts connected through that account")
      expect(response.body).not_to include("One of your GitHub App installations")
    end

    # The silent case on this page too: a 404 records no error, so nothing was said and a whole
    # organization simply was not there.
    it "names an installation GitHub no longer lists" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { not_found: true } : { repos: [github_repo("acme/api")] }))
      end

      get bulk_repositories_path

      expect(response.body).to include("GitHub no longer lists globex as connected to SpecGuard")
    end
  end

  describe "GET /repositories/bulk?organization= — choosing repositories" do
    it "lists the organization's repositories the App is installed on" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"),
                          github_repo("beta/elsewhere")])

      choose_organization("acme")

      expect(response.body).to include("acme/api")
      expect(response.body).to include("acme/web")
      expect(response.body).not_to include("beta/elsewhere")
    end

    # The page has to account for its own length. A member of `acme` who administers one of its two
    # connected repositories is offered one — and is told, in the same breath, that the other is
    # connected and simply not theirs to register. Without that sentence "my repository is not in
    # the list" is indistinguishable from "SpecGuard is broken".
    it "offers only what the viewer administers, and says how much it is withholding" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/legacy", admin: false)])

      choose_organization("acme")

      expect(response.body).to include("acme/api")
      expect(response.body).to include("1 repository you administer.")
      expect(response.body).to include("1 connected repository you do not administer is not listed.")
    end

    # And it stays quiet when there is nothing to account for, which is the ordinary case.
    it "says nothing about withheld repositories when none was withheld" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/legacy")])

      choose_organization("acme")

      expect(response.body).to include("2 repositories you administer.")
      expect(response.body).not_to include("do not administer")
    end

    # Offering a tick box whose only possible outcome is "skipped" is offering a click that can
    # only fail.
    it "shows an already-registered repository as registered rather than as a choice" do
      create_repository(user: @user, github_full_name: "acme/api")
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      choose_organization("acme")

      expect(response.body).to include("Already registered")
      expect(response.body).to include("already registered and cannot be")
    end

    it "says so when there is nothing left to register in the organization" do
      create_repository(user: @user, github_full_name: "acme/api")
      stub_github(repos: [github_repo("acme/api")])

      choose_organization("acme")

      expect(response.body).to include("Nothing left to register")
    end

    # A stale bookmark, a renamed account and a typed query string are ordinary ways to arrive
    # here. None of them is an error page.
    it "falls back to the chooser for an account the user cannot register from" do
      stub_github(repos: [github_repo("acme/api")])

      choose_organization("strangers")

      expect(response).to have_http_status(:ok)
      expect(response.body)
        .to include("Accounts with repositories the SpecGuard GitHub App is installed on")
    end

    # Step two for a personal namespace — the half a chooser that offered the card would be a lie
    # without. `GithubOrganizations.find` reads whatever `.from` offers, so this resolves on the
    # same terms, and the picker itself never asked what kind of owner it was rendering.
    it "lists a personal namespace's repositories when it is the one picked" do
      stub_github(repos: [github_repo("octocat/api", owner_type: "User"),
                          github_repo("octocat/blog", owner_type: "User"),
                          github_repo("acme/elsewhere")])

      choose_organization("octocat")

      expect(response.body).to include("octocat/api")
      expect(response.body).to include("octocat/blog")
      expect(response.body).not_to include("acme/elsewhere")
    end

    # Criterion 4 at this layer: the withheld sentence is per NAMESPACE and says the same thing for
    # a personal one, because it is computed from `admin?` and never read an owner type.
    it "offers only what the viewer administers in a personal namespace, and says what it withheld" do
      stub_github(repos: [github_repo("octocat/api", owner_type: "User"),
                          github_repo("octocat/theirs", owner_type: "User", admin: false)])

      choose_organization("octocat")

      expect(response.body).to include("octocat/api")
      expect(response.body).to include("1 repository you administer.")
      expect(response.body).to include("1 connected repository you do not administer is not listed.")
    end
  end

  describe "POST /repositories/bulk — registering" do
    it "registers the selected repositories and reports what it did" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      expect { submit(%w[acme/api acme/web]) }.to change(Repository, :count).by(2)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Registered 2 repositories.")
      expect(@user.repositories.pluck(:github_full_name)).to match_array(%w[acme/api acme/web])
    end

    # Criterion 1's final half, and the whole point of the ticket: the batch actually REGISTERS a
    # personal namespace's repositories. The pipeline could always do this — all three of
    # `BulkRegistration`'s passes gate on `admin?` and read no owner type — so this example is here
    # to pin that the chooser was the only thing standing in the way, and that nothing downstream
    # quietly disagrees.
    it "registers a personal namespace's repositories in one batch" do
      stub_github(repos: [github_repo("octocat/api", owner_type: "User"),
                          github_repo("octocat/blog", owner_type: "User")])

      expect { submit(%w[octocat/api octocat/blog], organization: "octocat") }
        .to change(Repository, :count).by(2)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Registered 2 repositories.")
      expect(@user.repositories.pluck(:github_full_name))
        .to match_array(%w[octocat/api octocat/blog])
    end

    # Criterion 6 where it matters most: widening the CHOOSER widened nothing about what may be
    # written. A personal repository the viewer does not administer is refused by the same
    # re-verification that refuses an organization's, however it was submitted.
    #
    # The refusal is "not an administrator" rather than "not connected", and the difference is the
    # point: the repository IS in the installation and GitHub answers about it happily — it is
    # `permissions.admin` that says no. That is the gate the whole ticket rests on being untouched.
    it "refuses a personal repository the viewer does not administer" do
      stub_github(repos: [github_repo("octocat/theirs", owner_type: "User", admin: false)])

      expect { submit(%w[octocat/theirs], organization: "octocat") }
        .not_to change(Repository, :count)

      expect(response.body).to include("You are not an administrator")
      expect(response.body).to include("GitHub does not list you as an administrator of it")
    end

    # The honest summary the ticket asks for: two numbers that add up to the submission, with the
    # skips broken down by reason rather than collapsed into a single failure.
    it "reports registered and skipped separately, with the reason for each skip" do
      create_repository(user: @user, github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/taken")])

      submit(%w[acme/api acme/theirs acme/taken])

      expect(response.body).to include("Registered 1 repository.")
      expect(response.body).to include("Skipped 2.")
      expect(response.body).to include("Already registered (1)")
      expect(response.body).to include("Not connected to the SpecGuard GitHub App (1)")
      expect(response.body)
        .to include("is not one of the repositories the SpecGuard GitHub App is installed on")
    end

    # THE example for this slice. The form is not the gate: a POST naming a repository the page
    # never offered is refused by asking GitHub which repositories the App is installed on, exactly
    # as a single registration is.
    it "refuses a repository outside the installation even when the form never offered it" do
      stub_github(repos: [github_repo("acme/api")])

      expect { submit(%w[someone-else/theirs]) }.not_to change(Repository, :count)

      expect(response.body).to include("Not connected to the SpecGuard GitHub App")
    end

    # A repository GitHub has never heard of gets the very same heading, and the summary says the
    # one thing it can honestly say. An installation credential is answered 404 for everything
    # outside the installation, so "nobody selected it" and "it does not exist" arrive here
    # indistinguishable, and a page that claimed the second would be guessing.
    it "names a repository GitHub cannot see no differently from an unselected one" do
      stub_github(repos: [github_repo("acme/api")])

      expect { submit(%w[ghost/repo]) }.not_to change(Repository, :count)

      expect(response.body).to include("Not connected to the SpecGuard GitHub App")
      expect(response.body).to include("Add it on GitHub, then pick it here.")
    end

    # Fails closed: an outage that registered by default would reopen the squatting gap on every
    # GitHub 500.
    it "registers nothing while GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect { submit(%w[acme/api acme/web]) }.not_to change(Repository, :count)

      expect(response.body).to include("GitHub could not be reached")
    end

    it "offers the install button when the batch was refused for a missing installation" do
      uninstall_github_app(@user)

      expect { submit(%w[acme/api]) }.not_to change(Repository, :count)

      expect(response.body).to include("Connect your GitHub repositories")
    end

    # The install button on the summary has to come back to the bulk page, and the summary is a POST
    # response: `request.fullpath` — what `github_install_button` falls back to — is the POST path,
    # so the view passes `return_to:` explicitly. The two happen to be the same URL on this route,
    # which is exactly why the explicit value has to be pinned rather than trusted to coincide.
    #
    # The App is deliberately unconfigured across the suite (no id, no private key — see
    # spec/support/github_api.rb), and an unconfigured instance renders the operator's notice
    # instead of a button that could only bounce the reader to a placeholder GitHub URL. Configuring
    # it for this one example is what makes the button — and its return path — exist to assert on.
    it "returns the user to the bulk page after installing from a refused batch" do
      allow(SpecGuard::GithubApp).to receive(:configured?).and_return(true)
      uninstall_github_app(@user)

      submit(%w[acme/api])

      expect(response.body)
        .to include(CGI.escapeHTML("return_to=#{CGI.escape(bulk_repositories_path)}"))
    end

    it "links to each repository it registered" do
      stub_github(repos: [github_repo("acme/api")])

      submit(%w[acme/api])

      expect(response.body).to include(repository_path(Repository.find_by(github_full_name: "acme/api")))
    end

    # The summary is RENDERED rather than redirected to (see the controller's class comment), and
    # Turbo Drive refuses a non-redirect response to a form submission — it logs "Form responses
    # must redirect to another location" and leaves the page untouched. So the picker form opts out
    # of Turbo, and that opt-out is the only reason the summary is reachable in a browser at all.
    #
    # Pinned here because the failure is SILENT: the repositories are registered either way, and
    # every other example in this file still sees the rendered summary in `response.body` — only a
    # real browser notices the user never gets it. Removing `turbo: false` from `_picker.html.erb`
    # must break something, and this is that something at this layer. See
    # spec/system/bulk_registration_spec.rb for the same claim through an actual browser.
    it "opts the picker form out of Turbo so the rendered summary reaches the browser" do
      stub_github(repos: [github_repo("acme/api")])

      choose_organization("acme")

      form = Capybara.string(response.body).find("form[action='#{bulk_repositories_path}']")
      expect(form[:"data-turbo"]).to eq("false")
    end

    # The create path has already walked the installation's listing inside
    # `InstallationRepositories.verify_batch`. Re-deriving "does this user need to install the App?"
    # from the listing afterwards costs a second full page walk — up to `GithubApi::MAX_PAGES` round
    # trips — to answer a question the verdict already holds.
    # `GithubRepositoryListing#github_installation_needed?` reads the verdict first.
    it "asks GitHub for the listing exactly once across a registration" do
      fake = stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      submit(%w[acme/api acme/web])

      expect(response.body).to include("Registered 2 repositories.")
      expect(fake.calls_to(:repositories)).to eq(1)
    end
  end

  # SPGD-824. Three skip reasons end their own sentence by telling the reader to try again, and the
  # summary used to answer that instruction with two exits that both threw the batch away: the only
  # way back to the picker was `bulk_repositories_path` with no organization — step ONE, the account
  # chooser, with a fresh unticked list waiting behind it.
  #
  # The mechanism is not new. The 422 refusal path has round-tripped the account and the ticks since
  # this feature shipped ("comes back to the same organization after refusing a submission", below),
  # through `params[:organization]` and the picker's `@full_names` seam. These examples pin the same
  # round trip on the 200 summary path, which is the one where losing the selection actually costs
  # something — the reader has just watched N repositories fail.
  describe "carrying a transiently-failed batch back to the picker" do
    # A mixed batch is the ordinary multi-installation shape rather than a contrivance, and it is
    # worth being precise about WHICH mechanism produces it, because the fixture is doing real work.
    #
    # `collect` concatenates the repositories of the installations that answered while recording the
    # failure of the one that did not, so the reading is INCOMPLETE. `name_verdict` then splits the
    # submitted names on exactly that: a name present in what was read, and administered, is
    # `:verified` and registers; a name ABSENT from an incomplete reading cannot be refused as
    # "not in the installation" — we do not know that — so it becomes `sources.error`, the transient
    # status of whichever installation failed.
    #
    # So `readable` is the half of the account that answered, and any submitted name outside it is
    # the half that transiently failed. Both belong to the same account, which is the case that
    # matters: the retry has to carry them back to ONE picker.
    def submit_with_unreadable_installation(names, failure: { unavailable: true },
                                            readable: [github_repo("acme/api")])
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? failure : { repos: readable }))
      end

      submit(names)
    end

    # Criterion 1 and criterion 3 together, and they belong in one example because the control is
    # only correct if BOTH hold: it has to reach the picker for the right account, and carry the
    # failed names WITHOUT dragging along the one that registered.
    it "offers the skipped repositories back to the same account, and carries only those" do
      submit_with_unreadable_installation(%w[acme/api acme/web acme/legacy])

      expect(response.body).to include("Registered 1 repository.")
      expect(response.body).to include("Try these again")

      retry_link = Capybara.string(response.body).find_link("Try these again")[:href]
      query = Rack::Utils.parse_nested_query(URI.parse(retry_link).query)

      expect(URI.parse(retry_link).path).to eq(bulk_repositories_path)
      expect(query["organization"]).to eq("acme")
      expect(query["github_full_names"]).to match_array(%w[acme/web acme/legacy])
      expect(query["github_full_names"]).not_to include("acme/api")
    end

    # The other half of criterion 1: following the control has to actually produce a pre-ticked
    # picker. Asserting on the link alone would pin a URL that no page is obliged to honour — and
    # `#new` seeding `@full_names` is the half of this change that makes the tick appear, so it is
    # the half worth walking to.
    #
    # The second stub is the retry landing in a healthier moment — the installation answers now, so
    # the picker offers the whole account. `acme/api` registered on the first pass, so it comes back
    # as a disabled already-registered row rather than a tick: what is carried is the FAILED
    # remainder, not the submission.
    it "arrives at the picker with those repositories already ticked" do
      submit_with_unreadable_installation(%w[acme/api acme/web])
      retry_link = Capybara.string(response.body).find_link("Try these again")[:href]

      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"), github_repo("acme/legacy")])
      get retry_link

      expect(response).to have_http_status(:ok)

      picker = Capybara.string(response.body)
      expect(picker).to have_field(type: "checkbox", with: "acme/web", checked: true)
      expect(picker).to have_field(type: "checkbox", with: "acme/legacy", checked: false)
      expect(picker).to have_field(type: "checkbox", with: "acme/api", disabled: true, checked: false)
    end

    # A rate limit is the reason that most literally instructs a retry — "Try again in a few
    # minutes" — so it is the one this control exists for, and it must not read as an outage.
    it "offers the retry for a rate-limited batch" do
      submit_with_unreadable_installation(%w[acme/api acme/web], failure: { forbidden: :rate_limited })

      expect(response.body).to include("GitHub rate limit reached")
      expect(response.body).to include("Try these again")
    end

    # Criterion 2. A batch that failed only for reasons a re-run cannot fix must not offer one:
    # `already_registered` needs nothing, and `not_in_installation` needs somebody to install the
    # App on GitHub first. Offering "try these again" here would be promising something the second
    # submission would refuse identically.
    it "does not offer a retry when every skip is terminal" do
      create_repository(user: @user, github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/taken")])

      submit(%w[acme/api acme/theirs acme/taken])

      expect(response.body).to include("Skipped 2.")
      expect(response.body).to include("Already registered (1)")
      expect(response.body).to include("Not connected to the SpecGuard GitHub App (1)")
      expect(response.body).not_to include("Try these again")
    end

    # And the batch where nothing was skipped at all has nothing to carry.
    it "does not offer a retry when the whole batch registered" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      submit(%w[acme/api acme/web])

      expect(response.body).to include("Registered 2 repositories.")
      expect(response.body).not_to include("Try these again")
    end

    # Criterion 4. Carrying a name back does not exempt it from the picker's existing display
    # concession: a repository somebody registered while this reader was reading the summary arrives
    # as a disabled "Already registered" row rather than as a tick. The picker asks
    # `!taken && @full_names.include?(...)`, so the carried list decides what is OFFERED and the
    # registration state still decides what is SELECTABLE — a carried name can never produce a tick
    # box whose only possible outcome is "skipped".
    it "shows a carried repository that has since been registered as already registered" do
      # `acme/web` is the name this example turns on, so it has to be the name that FAILS: it is
      # absent from `readable`, so it is what the retry carries. Submitting a name that registers
      # (or one from another account) would leave the carried list without it, and the assertion
      # below would then be pinning the ordinary already-registered row — true of any taken
      # repository, and true with the picker's `!taken &&` guard deleted.
      submit_with_unreadable_installation(%w[acme/api acme/web])
      retry_link = Capybara.string(response.body).find_link("Try these again")[:href]

      # The guard against exactly that drift: this example is only about a carried name, so if a
      # future edit to `readable` (or to the fixture's split of the account) stops `acme/web` being
      # carried, fail HERE and say why, rather than passing on a row that proves nothing.
      carried = Rack::Utils.parse_nested_query(URI.parse(retry_link).query)["github_full_names"]
      expect(carried).to include("acme/web")

      # Somebody else gets there first, in the gap between the summary and the retry. A distinct
      # `github_uid` because the signed-in user already holds the default one.
      create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                        github_full_name: "acme/web")
      # `acme/legacy` keeps a registerable row on the page: `acme/api` registered on the first pass
      # and `acme/web` has just been taken, and a picker with nothing left to register renders the
      # "Nothing left to register" empty state instead of the form — which would pass an assertion
      # about the absence of a tick for the wrong reason entirely.
      stub_github(repos: [github_repo("acme/web"), github_repo("acme/api"), github_repo("acme/legacy")])

      get retry_link

      picker = Capybara.string(response.body)
      expect(picker).to have_field(type: "checkbox", with: "acme/web", disabled: true, checked: false)
      # `acme/legacy` is the control: same page, same carried-name treatment available, but nobody
      # took it — so it proves the row above is disabled because it is TAKEN rather than because
      # the retry landed on a picker that disables everything.
      expect(picker).to have_field(type: "checkbox", with: "acme/legacy", disabled: false)
    end

    # Criterion 5. The retry is an addition, not a replacement — the two exits that were already
    # there still go where they went, and "Register another batch" still means the BARE picker (a
    # fresh account choice) rather than a second door onto the carried batch.
    it "keeps the two existing exits meaning what they meant" do
      submit_with_unreadable_installation(%w[acme/api globex/tools])

      page = Capybara.string(response.body)
      expect(page.find_link("Back to repositories")[:href]).to eq(repositories_path)
      expect(page.find_link("Register another batch")[:href]).to eq(bulk_repositories_path)
    end

    # The control is a GET to the picker rather than a re-submission. Re-registering behind the
    # reader's back would be safe (the operation is idempotent — see the controller's header), but a
    # rate limit is precisely the refusal that asks a human to decide WHEN, so the button stops one
    # step short and hands them a form. Also keeps the summary's own promise honest: the panel says
    # "you can submit this batch again", and this is what lets them.
    it "returns the reader to the form rather than re-registering for them" do
      submit_with_unreadable_installation(%w[acme/api globex/tools])
      retry_link = Capybara.string(response.body).find_link("Try these again")[:href]

      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      expect { get retry_link }.not_to change(Repository, :count)
      expect(response.body).to include("Register selected repositories")
    end
  end

  describe "refusing a submission before it reaches GitHub" do
    it "asks again when nothing was selected" do
      fake = stub_github(repos: [github_repo("acme/api")])

      submit([])

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Select at least one repository")
      expect(fake.calls_to(:repository)).to eq(0)
    end

    # A bound rather than a queue — the ticket puts scheduling out of scope, so an oversized batch
    # is refused honestly instead of silently registering a prefix of it.
    it "refuses a batch larger than one action may carry, and registers none of it" do
      names = Array.new(BulkRegistration::MAX_BATCH + 1) { |i| "acme/repo-#{i}" }
      stub_github(repos: names.map { |name| github_repo(name) })

      expect { submit(names) }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("more than one batch can register")
    end

    it "comes back to the same organization after refusing a submission" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      submit([])

      expect(response.body).to include("acme/api")
      expect(response.body).to include("acme/web")
    end

    # The cap is measured against the batch that would actually RUN, not against the raw params.
    # A submission that collapses to one repository is one repository, and refusing it with
    # "101 repositories is more than one batch can register" would be a true sentence about a batch
    # the user did not submit.
    it "measures the batch cap after de-duplication, not before" do
      names = Array.new(BulkRegistration::MAX_BATCH + 1) { "acme/api" }
      stub_github(repos: [github_repo("acme/api")])

      expect { submit(names) }.to change(Repository, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Registered 1 repository.")
    end

    # De-duplication runs on the NORMALISED name, so the two spellings of one repository do not
    # survive as two candidates — which would register the first and then report the second as
    # already-registered against a row this very batch had just created.
    it "treats a URL and a bare slug for one repository as one repository" do
      stub_github(repos: [github_repo("acme/api")])

      expect { submit(["acme/api", "https://github.com/acme/api", "acme/api.git"]) }
        .to change(Repository, :count).by(1)

      expect(response.body).to include("Registered 1 repository.")
      expect(response.body).not_to include("Already registered")
    end

    # `params` can be any shape a client cares to send. A Hash where an Array is expected, and
    # non-scalar entries, must not become a 500 or a repository named `{"a"=>"b"}`.
    it "survives a submission that is not the shape the form sends" do
      stub_github(repos: [github_repo("acme/api")])

      post bulk_repositories_path, params: { github_full_names: { "0" => "acme/api", "1" => "" } }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Registered 1 repository.")
    end

    it "ignores non-scalar entries rather than naming them as repositories" do
      stub_github(repos: [github_repo("acme/api")])

      post bulk_repositories_path,
           params: { github_full_names: ["acme/api", { "nested" => "value" }] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Registered 1 repository.")
      expect(response.body).not_to include("nested")
    end
  end

  describe "when GitHub will not answer at all" do
    it "explains an outage rather than rendering an empty chooser" do
      stub_github(unavailable: true)

      get bulk_repositories_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("GitHub is not answering right now")
      expect(response.body).not_to include("Reconnect to GitHub")
    end

    # A 401 is not an outage. The only credential on this read is the viewer's own session token —
    # there is no App id and no private key in this codebase to have been rejected instead — so it
    # means the token expired or was revoked mid-session, which the session cannot tell for itself
    # because the stored expiry has not lapsed yet. The fix is a click, and this page offers the
    # same button the single-repository form does rather than sending the reader away to wait.
    it "offers the reconnect button when GitHub rejects the user's token" do
      # Configured so the real button renders rather than the operator notice that stands in for it.
      allow(SpecGuard::GithubApp).to receive_messages(configured?: true, slug: "specguard")
      stub_github(unauthorized: true)

      get bulk_repositories_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Reconnect to GitHub")
      expect(response.body).to include(github_installation_authorize_path)
      expect(response.body).not_to include("GitHub is not answering right now")
    end

    # GitHub answered here, and said no — so "try again shortly" would be describing something else.
    # A rate limit is the one refusal that genuinely clears on its own, and it says how, which is
    # the same distinction the single-repository form makes.
    it "names the rate limit rather than reporting it as an outage" do
      stub_github(forbidden: :rate_limited)

      get bulk_repositories_path

      expect(response.body).to include("GitHub refused the request")
      expect(response.body).to include("rate limit")
      expect(response.body).not_to include("GitHub is not answering right now")
    end

    it "offers the installation when the user has never connected GitHub" do
      uninstall_github_app(@user)

      get bulk_repositories_path

      expect(response.body).to include("Connect your GitHub repositories")
    end
  end

  describe "authentication" do
    it "does not let a signed-out visitor reach the picker or register anything" do
      delete sign_out_path

      get bulk_repositories_path
      expect(response).to redirect_to(root_path)

      expect { submit(%w[acme/api]) }.not_to change(Repository, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  it "is reachable from the repositories index" do
    get repositories_path

    expect(response.body).to include(bulk_repositories_path)
  end
end
