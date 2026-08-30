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

    # The same silence as the single-repository picker's, on the same mechanism, in the branch that
    # never asked. A 404'd installation contributes no registrable repositories, so it can empty this
    # chooser BY ITSELF — and the sentence below would then explain that emptiness as somebody else's
    # admin rights over an account nobody could read.
    #
    # The sole-installation shape, where the emptiness and the unread account are the same event.
    it "names the sole installation GitHub no longer lists rather than blaming admin rights" do
      stub_github(not_found: true)

      get bulk_repositories_path

      expect(response.body).to include("GitHub no longer lists acme as connected to SpecGuard")
      # The claim that must be withheld: it quantifies over EVERY account the App is installed on,
      # and one of them was not read, so it is not a thing this page knows.
      expect(response.body).not_to include("No repositories to register in a batch")
      expect(response.body).not_to include("does not list you as an administrator of any repository")
    end

    # The closing clause, which is the one part of the sentence that cannot be shared with the
    # chooser's own notice: this page is showing nothing, so an offer about what is shown is false.
    # Worded identically to the single-repository picker's empty state — one helper decides it, which
    # is the whole reason the helper exists.
    it "does not close an empty chooser by offering what it is not showing" do
      stub_github(not_found: true)

      get bulk_repositories_path

      expect(response.body).to include("could not be listed, so this page may be empty for that " \
                                       "reason rather than because there is nothing to register")
      expect(response.body).not_to include("Anything shown here can still be registered")
    end

    # Empty for the ORIGINAL reason plus an unread account: one installation answers with
    # repositories this viewer administers none of, and a second 404s. The chooser is empty either
    # way, and the reader is owed both facts rather than only the one this page could already see.
    it "names an unread account when another installation emptied the chooser" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { not_found: true } : { repos: [github_repo("acme/api", admin: false)] }))
      end

      get bulk_repositories_path

      expect(response.body).to include("GitHub no longer lists globex as connected to SpecGuard")
      expect(response.body).not_to include("does not list you as an administrator of any repository")
    end

    # The negative that keeps this from being "always warn". A viewer who genuinely administers
    # nothing has every installation ANSWERING, so there is no account to name and the original
    # sentence is the true one — it must still be exactly what they are told.
    it "still says nothing is theirs to register when every installation answered" do
      stub_github(repos: [github_repo("acme/api", admin: false)])

      get bulk_repositories_path

      expect(response.body).to include("No repositories to register in a batch")
      expect(response.body).to include("does not list you as an administrator of any repository")
      expect(response.body).not_to include("An account could not be read")
      expect(response.body).not_to include("GitHub no longer lists")
      expect(response.body).not_to include("SpecGuard could not read")
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

    # The way OUT of this page, held to the narrow reading SPGD-802 settled: "Back to repositories"
    # lands on the UNFILTERED list. The index now reads narrowing parameters off the URL, which
    # makes this link a place a filter could plausibly leak through — carried from a referrer or
    # reconstructed from session state — and this pins that it does not: the bare path, no query
    # string, the whole list. (Today the link is a static `repositories_path` and cannot carry
    # anything; the guard exists so a future edit that changes that has to read this first.)
    it "links back to the unfiltered repositories list" do
      stub_github(repos: [github_repo("acme/api")])

      submit(%w[acme/api])

      expect(response).to have_http_status(:ok)
      link = Capybara.string(response.body).find_link("Back to repositories")
      expect(link[:href]).to eq(repositories_path)
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

  # SPGD-828. `06ec58f` taught ONE of the summary's three controls to preserve the batch and left
  # the two beside it discarding it — so a reader whose batch was skipped for a dead credential saw
  # "Reconnect to GitHub" (the correct fix, which threw every tick away) next to "Try these again"
  # (which kept all N and fixed nothing, because the credential was still dead). Pressing the one
  # that WORKED cost them the selection and a hand re-pick of N repositories: the precise labour the
  # retry control had just been built to remove.
  #
  # These examples are about the two FIX buttons. What "Try these again" carries is pinned above and
  # must not change — see "keeping the two carried lists apart".
  describe "carrying the batch on the controls that fix a refusal" do
    # The App is deliberately unconfigured across the suite (spec/support/github_api.rb), and an
    # unconfigured instance renders the operator's notice INSTEAD of a button — so configuring it is
    # what makes a button exist to read a `return_to` off at all. Same move as the install example
    # further up this file.
    def configure_github_app
      allow(SpecGuard::GithubApp).to receive_messages(configured?: true, slug: "specguard")
    end

    # Both fix controls are `button_to`, so what carries the path is a FORM ACTION rather than an
    # href — and the value under test is nested one level down inside it, as `?return_to=<path>`.
    # Parsed rather than matched as a substring, twice, because a substring assertion passes on a
    # path that merely CONTAINS the right characters: `?organization=acmecorp` contains
    # `organization=acme`.
    def carried_return_to(body, action_path)
      form = Capybara.string(body).find("form[action*='#{action_path}']")
      Rack::Utils.parse_nested_query(URI.parse(form[:action]).query).fetch("return_to")
    end

    def carried_query(body, action_path)
      Rack::Utils.parse_nested_query(URI.parse(carried_return_to(body, action_path)).query)
    end

    # WHICH REPOSITORIES THE BUTTON ACTUALLY CARRIES BACK, however it carries them.
    #
    # SPGD-840 moved the fix buttons from carrying the NAMES in the query string to carrying a
    # HANDLE to a selection held server-side, because the names rode out through GitHub's `state`
    # and only 28 of the 100 legal batch sizes fit — above which every name was dropped. So the
    # examples below stopped being able to read `query["github_full_names"]` and get an answer.
    #
    # They are re-aimed HERE rather than at each call site, and re-aimed rather than deleted,
    # because what they were pinning was never the mechanism: it was "this button carries THIS
    # batch, and not the one the button beside it carries". That question is unchanged, and it is
    # the question this answers. An example that asserted the parameter name instead would have
    # been pinning an implementation detail the ticket's whole remedy was to change.
    #
    # Reads EITHER carry deliberately. The name carry is still live — `bulk_picker_return_to`
    # falls back to it for a caller with no user to scope a handle to, and for a capture that did
    # not land — so an assertion that could only read handles would go quietly vacuous on those
    # paths rather than failing.
    #
    # Resolves through `PendingBulkSelection.redeem` with the signed-in user, which is exactly the
    # call `BulkRegistrationsController#new` makes. That is the point: a handle scoped to somebody
    # else redeems nothing HERE for the same reason it redeems nothing THERE, so an example using
    # this cannot accidentally pass by reading a row the reader could not have read.
    def carried_names(body, action_path)
      query = carried_query(body, action_path)
      return query["github_full_names"].to_a if query["github_full_names"].present?

      PendingBulkSelection.redeem(user: @user, token: query[GithubHelper::SELECTION_PARAM.to_s])
    end

    # Criterion 1. A dead session credential is the case the whole ticket turns on: `:not_authorized`
    # is in BOTH vocabularies at once — it drives `authorize?` AND is a member of `RETRYABLE_SKIPS` —
    # so the reconnect panel and the retry panel render together, and the reader has to choose. Now
    # both choices keep the batch.
    it "carries the account and the skipped names on the reconnect button" do
      configure_github_app
      stub_github(unauthorized: true)

      submit(%w[acme/api acme/web])

      expect(response.body).to include("Reconnect to GitHub")

      path = carried_return_to(response.body, github_installation_authorize_path)
      query = carried_query(response.body, github_installation_authorize_path)

      expect(URI.parse(path).path).to eq(bulk_repositories_path)
      expect(query["organization"]).to eq("acme")
      expect(carried_names(response.body, github_installation_authorize_path))
        .to match_array(%w[acme/api acme/web])
    end

    # Criterion 2. Asserting on the emitted path alone would pin a URL nothing is obliged to honour,
    # so this walks the whole round trip the button starts: out through GitHub's `state`, back
    # through the callback's redirect, and onto the picker — and then reads the TICKS, which are the
    # only thing the reader actually cares about. Same shape as SPGD-824's own walk for "Try these
    # again", one control along.
    it "arrives back at the picker with those repositories ticked after reconnecting" do
      configure_github_app
      stub_github(unauthorized: true)

      submit(%w[acme/api acme/web])
      state = carried_return_to(response.body, github_installation_authorize_path)

      # GitHub's half of the trip, stubbed at the same service seam the callback's own specs use.
      allow(GithubAppUserAuthorization).to receive(:authorize).and_return(
        GithubAppUserAuthorization::Authorization.new(
          token: "ghu_reconnected", expires_at: 1.hour.from_now,
          installations: [GithubAppUserAuthorization::Installation.new(installation_id: 6001,
                                                                       account_login: "acme")]
        )
      )
      # The reconnect landing in a healthier moment: the credential works now, so the account reads.
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"), github_repo("acme/legacy")])

      get github_installation_callback_path, params: { code: "abc", state: state }
      expect(response).to redirect_to(state)

      follow_redirect!

      picker = Capybara.string(response.body)
      expect(picker).to have_field(type: "checkbox", with: "acme/api", checked: true)
      expect(picker).to have_field(type: "checkbox", with: "acme/web", checked: true)
      # The control: a registerable row on the same page that was NOT carried, so the two ticks
      # above are the carried batch rather than a picker that ticks everything.
      expect(picker).to have_field(type: "checkbox", with: "acme/legacy", checked: false)
    end

    # Criterion 3, and the list it pins is the one the install button is owed: `not_installed` names
    # are what installing the App actually makes registerable, so a list omitting them would carry
    # back everything EXCEPT what the button just fixed.
    #
    # The ticket asked for this on a batch holding BOTH kinds of skip at once. That batch is not
    # reachable: `InstallationRepositories.verify_batch` short-circuits on `sources.installed?` and
    # answers `:not_installed` for every name or for none, so `install?` and `retry?` are never both
    # true through the service. The asymmetry is still reachable, and this is where it bites — the
    # two lists differ here, and an implementation that collapsed them into one carries ZERO names
    # on this button and fails. The both-at-once case is pinned at the layer that decides it, in
    # spec/services/bulk_registration_spec.rb.
    it "carries the not-installed names on the install button" do
      configure_github_app
      uninstall_github_app(@user)

      submit(%w[acme/api acme/web])

      expect(response.body).to include("Connect your GitHub repositories")

      query = carried_query(response.body, github_installation_path)

      expect(query["organization"]).to eq("acme")
      expect(carried_names(response.body, github_installation_path)).to match_array(%w[acme/api acme/web])
      # The retry control is not on this page to disagree with: nothing here is retryable, which is
      # exactly why the install button carrying `retryable_names` would carry nothing.
      expect(response.body).not_to include("Try these again")
    end

    # Criterion 4. An invariant in N rather than one pinned example, because the failure this guards
    # is a size-dependent one: the batch rides out through GitHub's `state`, which is part of a URL
    # on somebody else's site, and a path that grows without bound is a button that silently stops
    # working somewhere past the example anyone happened to write.
    it "keeps the emitted path within the byte bound at every batch size" do
      configure_github_app

      # Representative 25-character names, which is what the bound was derived against — the real
      # cost is the escaping of `/` and the repeated `github_full_names[]=`, not the names.
      names = (1..BulkRegistration::MAX_BATCH).map { |i| format("acmecorp/repository-%05d", i) }

      (1..BulkRegistration::MAX_BATCH).each do |size|
        path = helper_return_to(names.first(size))

        expect(path.bytesize).to be <= GithubHelper::MAX_RETURN_TO_BYTES,
                                 -> { "#{size} names emitted #{path.bytesize} bytes" }
      end
    end

    # Criterion 5. Over the bound the names are dropped ENTIRELY, never truncated — asserted as
    # exactly zero, so an implementation that carried "as many as fit" fails here rather than
    # passing with fewer names than the reader submitted.
    #
    # A partially-ticked picker is WORSE than an unticked one: the reader submits believing it
    # complete and loses the remainder without ever being told a list was shortened. Degraded to the
    # account alone is honest, and still better than the account chooser this replaced.
    it "drops the names rather than truncating them when the batch will not fit" do
      configure_github_app

      names = (1..BulkRegistration::MAX_BATCH).map { |i| format("acmecorp/repository-%05d", i) }
      query = Rack::Utils.parse_nested_query(URI.parse(helper_return_to(names)).query)

      expect(query["github_full_names"].to_a.length).to eq(0)
      # And the half that is never dropped: the account alone is what lands the reader on the right
      # picker instead of back at the chooser, which is the whole of the degraded promise.
      expect(query["organization"]).to eq("acme")
    end

    # Criterion 6. A POST that did not come from the picker carries no organization, and then there
    # is nothing to name — so the button emits the bare path exactly as it did before this change.
    # Asserted as an exact equality, so an `organization=` with nothing after it (which would claim
    # to know an account we do not) fails rather than passing an `include?`.
    it "emits the bare path when the submission named no organization" do
      configure_github_app
      stub_github(unauthorized: true)

      post bulk_repositories_path, params: { github_full_names: %w[acme/api] }

      expect(response.body).to include("Reconnect to GitHub")
      expect(carried_return_to(response.body, github_installation_authorize_path))
        .to eq(bulk_repositories_path)
    end

    # Criterion 7. The unconfigured branch short-circuits before either helper builds a path, and
    # that stays true: what a reader cannot do they are told about instead of offered, and carrying
    # a batch on a button that cannot work would be the wrong half to fix.
    it "still renders the operator notice rather than a button when the App is unconfigured" do
      stub_github(unauthorized: true)

      submit(%w[acme/api])

      expect(response.body).to include("The SpecGuard GitHub App is not configured")
      expect(response.body).not_to include(github_installation_authorize_path)
    end

    # SPGD-833. The THIRD fix control, and the branch this cascade used to fall through entirely.
    #
    # `create.html.erb` renders one `if github_installation_needed? … elsif
    # github_authorization_needed? … end`, and a batch skipped only for `:not_in_installation` makes
    # BOTH false — the App is installed and the credential is fine. So the reader got the "Not
    # connected to the SpecGuard GitHub App (N)" heading and no control at all, while that skip's
    # own sentence told them to "Add it on GitHub, then pick it here."
    #
    # Criterion 1, and it asserts BOTH halves the way the reconnect example above does: the panel
    # renders, and the path it carries reaches the right picker with the right names on it.
    it "offers GitHub's repository picker when the batch is only outside the installation" do
      configure_github_app
      stub_github(repos: [github_repo("acme/api")])

      submit(%w[acme/theirs acme/ghost])

      expect(response.body).to include("Choose repositories on GitHub")

      path = carried_return_to(response.body, github_installation_path)
      query = carried_query(response.body, github_installation_path)

      expect(URI.parse(path).path).to eq(bulk_repositories_path)
      expect(query["organization"]).to eq("acme")
      expect(carried_names(response.body, github_installation_path)).to match_array(%w[acme/theirs acme/ghost])

      # The POSITIVE half of the promise, pinned so the two degraded examples below cannot be
      # satisfied by simply deleting the clause everywhere. The names DID survive here, so the
      # panel says so — the sentence is conditional on what the path carries, not withdrawn.
      expect(response.body).to include("already selected")
    end

    # The other half of criterion 1, walked rather than asserted on a URL nothing is obliged to
    # honour — same shape as the reconnect walk above, one control along. The trip out is GitHub's
    # own repository picker, so the return leg is the installation callback (which documents itself
    # as the setup URL "after an install OR a reconfigure"), and what the reader actually cares
    # about at the end of it is the TICKS.
    it "arrives back at the picker with those repositories ticked after choosing them" do
      configure_github_app
      stub_github(repos: [github_repo("acme/api")])

      submit(%w[acme/theirs acme/api])
      state = carried_return_to(response.body, github_installation_path)

      # The reconfigure landing: the reader ticked `acme/theirs` on GitHub, so the App is now
      # installed on it and the account reads in full.
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/theirs"),
                          github_repo("acme/legacy")])

      get github_installation_callback_path, params: { installation_id: 6001, state: state }
      expect(response).to redirect_to(state)

      follow_redirect!

      picker = Capybara.string(response.body)
      expect(picker).to have_field(type: "checkbox", with: "acme/theirs", checked: true)
      # The control: a registerable row on the same page that was NOT carried, so the tick above is
      # the carried batch rather than a picker that ticks everything.
      expect(picker).to have_field(type: "checkbox", with: "acme/legacy", checked: false)
      # `acme/api` registered on the first pass, so it comes back as a disabled already-registered
      # row rather than a tick: what is carried is the failed remainder, not the submission.
      expect(picker).to have_field(type: "checkbox", with: "acme/api", disabled: true, checked: false)
    end

    # Criterion 3, and the deliberate exclusion asserted rather than merely absent. The fix for
    # `not_administered` belongs to somebody ELSE — the reader's selection on GitHub is already
    # correct — so sending them to the picker would be sending them to fix something that is not
    # broken while what is actually in their way stays untouched. `repositories/_form` states this
    # reason in full at the same decision.
    #
    # Asserted as NO GitHub button at all rather than as an absent label, so an implementation that
    # renders the panel with different wording fails here too.
    it "offers no GitHub button for a batch skipped only because the user is not an administrator" do
      configure_github_app
      stub_github(repos: [github_repo("acme/vault", admin: false)])

      submit(%w[acme/vault])

      expect(response.body).to include("You are not an administrator (1)")
      expect(response.body).not_to include("Choose repositories on GitHub")
      expect(response.body).not_to include(github_installation_path)
      expect(response.body).not_to include(github_installation_authorize_path)
      expect(response.body).not_to include("Try these again")
    end

    # Criterion 4. The new branch is an `elsif` TAIL, never a second simultaneous panel: installing
    # the App is the wider fix and lands the reader on the same GitHub picker, so a batch holding
    # both takes the first branch and the narrower offer is not lost by being skipped.
    #
    # Driven through the VIEW with a hand-built result, deliberately, and for the reason the service
    # spec's own both-at-once example states: `InstallationRepositories.verify_batch` short-circuits
    # the whole batch on `sources.installed?` and answers `:not_installed` for every name or for
    # none, so a submission mixing the two cannot currently be produced by the service at all. It is
    # still what the cascade has to be right about — the day a per-installation verdict makes that
    # reading reachable, this must already render ONE panel rather than two.
    it "renders only the install panel for a batch holding both, never both panels" do
      configure_github_app
      outcomes = [BulkRegistration::Outcome.new(full_name: "acme/uninstalled", status: :not_installed),
                  BulkRegistration::Outcome.new(full_name: "acme/theirs", status: :not_in_installation)]
      result = BulkRegistration::Result.new(outcomes: outcomes)

      # Both questions are true of this result, which is what makes the ORDER the thing under test
      # rather than the branch conditions.
      expect(result).to be_install
      expect(result).to be_choose_repositories

      allow(BulkRegistration).to receive(:call).and_return(result)

      submit(%w[acme/uninstalled acme/theirs])

      expect(response.body).to include("Connect your GitHub repositories")
      expect(response.body).not_to include("Choose repositories on GitHub")
    end

    # SPGD-840 REVERSED THIS EXAMPLE, and the reversal is the whole ticket.
    #
    # It used to read "degrades to the account alone when the carried batch will not fit", and it
    # pinned a full-size batch arriving with ZERO names carried and the panel correctly declining to
    # promise ticks. That was an honest answer to a real bound: the names rode out through GitHub's
    # `state`, and only 28 of the 100 legal sizes fit.
    #
    # The names no longer ride out at all — `bulk_picker_return_to` carries a HANDLE to a selection
    # held server-side — so at MAX_BATCH the batch SURVIVES, and the degraded state this example was
    # written to pin is no longer reachable from this call site at any legal size. Re-aimed rather
    # than deleted, because the thing worth pinning was never the drop: it was that the path and the
    # SENTENCE agree. They still have to, and now they agree the other way.
    #
    # The rule the old version protected is not lost. "A path carrying no selection must never
    # promise ticks" still bites on the no-organization branch, and the example directly below is
    # where it is pinned; the all-or-nothing drop itself is still pinned at the helper, where it is
    # still reachable and still correct.
    #
    # Criteria 1 and 3 at MAX_BATCH — the largest batch the product accepts, and 72 sizes past the
    # last one that used to work.
    it "carries the whole batch and promises the ticks at the largest legal size" do
      configure_github_app
      names = (1..BulkRegistration::MAX_BATCH).map { |i| format("acmecorp/repository-%05d", i) }
      outcomes = names.map do |name|
        BulkRegistration::Outcome.new(full_name: name, status: :not_in_installation)
      end

      allow(BulkRegistration).to receive(:call).and_return(BulkRegistration::Result.new(outcomes: outcomes))

      submit(names)

      expect(response.body).to include("Choose repositories on GitHub")

      path = carried_return_to(response.body, github_installation_path)
      query = carried_query(response.body, github_installation_path)

      # EVERY name, not "as many as fit": a partially-carried batch is the failure the all-or-
      # nothing drop existed to prevent, and a handle must not reintroduce it by another route.
      expect(carried_names(response.body, github_installation_path)).to match_array(names)
      expect(query["organization"]).to eq("acme")

      # Criterion 2 at this call site. The bound is unchanged and still met — by carrying something
      # that does not grow, rather than by raising it.
      expect(path.bytesize).to be <= GithubHelper::MAX_RETURN_TO_BYTES

      # Criterion 3. The panel's sentence now agrees with what its path delivers, which is what the
      # old version asserted the other way round. A reader taking this trip is promised ticks and
      # gets them.
      expect(response.body).to include("already selected")
      expect(response.body).not_to include("where you can pick them again and submit")
    end

    # The same sentence, the other reachable way it can go wrong. `bulk_picker_return_to` returns
    # the BARE picker path when the POST carried no `organization` — so the reader lands on the
    # account chooser, not on a ticked list.
    #
    # The button itself is deliberately NOT guarded on `submitted_organization.present?` (unlike
    # the retry panel below): the bare path still lands the reader somewhere useful, which is the
    # same reasoning the install and authorize panels rely on. This pins that the COPY follows that
    # decision through rather than claiming a pre-selection the path cannot deliver.
    it "promises no pre-selection when the submission carried no organization" do
      configure_github_app
      outcomes = [BulkRegistration::Outcome.new(full_name: "acme/theirs", status: :not_in_installation)]

      allow(BulkRegistration).to receive(:call).and_return(BulkRegistration::Result.new(outcomes: outcomes))

      post bulk_repositories_path, params: { github_full_names: %w[acme/theirs] }

      expect(response.body).to include("Choose repositories on GitHub")

      path = carried_return_to(response.body, github_installation_path)

      # The bare picker path: no account to name, and so nothing ticked to promise.
      expect(URI.parse(path).query).to be_blank
      expect(response.body).not_to include("already selected")
      expect(response.body).to include("where you can pick it again and submit")
    end

    # SPGD-840. THE POPULATION THIS TICKET EXISTS FOR: batch sizes ABOVE 28.
    #
    # The fix buttons used to carry the reader's selection as `github_full_names[]` inside a path
    # that rides out through GitHub's `state`. That met its byte budget at 28 of the 100 sizes the
    # product accepts, and above 28 it dropped EVERY name — so a person who ticked thirty, was
    # refused, pressed the button that fixes it and came back landed on an unticked list and
    # re-picked thirty by hand. Precisely the cost the button exists to remove.
    #
    # These examples are all asserted ABOVE 28, because 28 and below already worked and an example
    # written there would have passed before this change too.
    describe "carrying a batch too large to fit in the URL" do
      # 25-CHARACTER names, which is what the byte bound was derived against — the real cost of the
      # old carry was the escaping of `/` and the repeated `github_full_names[]=`, not the names.
      # These reproduce the helper's own measurement table exactly: 28 of them emit a 1,492-byte
      # path and 29 emit 1,544, which are the last size that used to carry and the first that used
      # to drop.
      #
      # Owned by `acme` rather than by the table's `acmecorp`, and that is load-bearing here where
      # it was not there: these examples WALK the trip and read the ticks off the picker, and the
      # picker renders one organization. Names under a different owner than the `organization` the
      # batch was submitted for match no row, so the example would assert against an empty list and
      # fail for a reason that has nothing to do with the carry.
      def batch(size) = (1..size).map { |i| format("acme/repository-%09d", i) }

      # A batch refused for a DEAD CREDENTIAL, which is the case the reconnect button answers.
      # `:not_authorized` is what every name comes back as when the session has nothing to ask
      # GitHub with, and it is a member of `RETRYABLE_SKIPS`, so `retryable_names` is the whole
      # batch.
      def submit_unauthorized(size)
        configure_github_app
        stub_github(unauthorized: true)
        submit(batch(size))
      end

      # Criterion 1, walked rather than asserted on a URL nothing is obliged to honour — same shape
      # as the reconnect walk above, at a size that used to lose everything. What the reader
      # actually cares about at the end of the trip is the TICKS, so that is what this reads.
      #
      # 29 is not an arbitrary "big number": it is the FIRST size the old carry dropped, named in
      # the helper's own measurement table. An example at 30 or at 50 would pass just as well and
      # would not say where the boundary was.
      [29, BulkRegistration::MAX_BATCH].each do |size|
        it "brings all #{size} names back ticked after reconnecting" do
          names = batch(size)
          submit_unauthorized(size)

          state = carried_return_to(response.body, github_installation_authorize_path)

          # GitHub's half of the trip, stubbed at the same service seam the callback's own specs use.
          allow(GithubAppUserAuthorization).to receive(:authorize).and_return(
            GithubAppUserAuthorization::Authorization.new(
              token: "ghu_reconnected", expires_at: 1.hour.from_now,
              installations: [GithubAppUserAuthorization::Installation.new(installation_id: 6001,
                                                                          account_login: "acme")]
            )
          )
          # The reconnect landing in a healthier moment: the credential works now, so the account
          # reads. `acme/legacy` is the CONTROL — a registerable row on the same page that was not
          # carried, so the ticks below are the carried batch rather than a picker ticking
          # everything it renders.
          stub_github(repos: (names + ["acme/legacy"]).map { |name| github_repo(name) })

          get github_installation_callback_path, params: { code: "abc", state: state }
          expect(response).to redirect_to(state)

          follow_redirect!

          picker = Capybara.string(response.body)
          # EVERY name, not "as many as fit". A partially-ticked picker is the failure the
          # all-or-nothing drop existed to prevent, and a handle must not reintroduce it by another
          # route: the reader submits believing it complete and silently loses the remainder.
          names.each do |name|
            expect(picker).to have_field(type: "checkbox", with: name, checked: true)
          end
          expect(picker).to have_field(type: "checkbox", with: "acme/legacy", checked: false)
        end
      end

      # Criterion 3, on BOTH unconditioned panels, at the last size that used to work and at the
      # largest legal one.
      #
      # These two panels state their promise FLATLY — the authorize panel says "you can submit this
      # batch again" in so many words — where the third panel asks `bulk_picker_carries_names?`
      # first and words itself accordingly. That asymmetry was the defect: above 28 the page told
      # the reader their batch survived the trip, and it did not.
      #
      # Asserted as agreement between the SENTENCE and the PATH, which is the rule the third panel
      # already applied and these two did not. Making the sentence conditional would satisfy the
      # letter of that rule; the ticket asks for the sentence to be TRUE instead, so the assertion
      # is that the promise is made AND kept.
      [28, BulkRegistration::MAX_BATCH].each do |size|
        it "keeps the reconnect panel's promise at #{size} names" do
          names = batch(size)
          submit_unauthorized(size)

          expect(response.body).to include("Reconnect to GitHub")
          # The sentence, unconditioned — it is on the page at both sizes.
          expect(response.body).to include("you can submit this batch again")

          path = carried_return_to(response.body, github_installation_authorize_path)

          # And the path keeps it: every name, and the account to come back to.
          expect(carried_names(response.body, github_installation_authorize_path)).to match_array(names)
          expect(carried_query(response.body, github_installation_authorize_path)["organization"]).to eq("acme")

          # Criterion 2 at this call site: the bound is unchanged and still met, by carrying
          # something that does not grow rather than by raising it.
          expect(path.bytesize).to be <= GithubHelper::MAX_RETURN_TO_BYTES
        end

        it "keeps the install panel's promise at #{size} names" do
          configure_github_app
          uninstall_github_app(@user)
          names = batch(size)

          submit(names)

          expect(response.body).to include("Connect your GitHub repositories")

          path = carried_return_to(response.body, github_installation_path)

          expect(carried_names(response.body, github_installation_path)).to match_array(names)
          expect(carried_query(response.body, github_installation_path)["organization"]).to eq("acme")
          expect(path.bytesize).to be <= GithubHelper::MAX_RETURN_TO_BYTES
        end
      end

      # Criterion 2, stated as the thing it is really about. The remedy was NOT to raise the bound —
      # the bound belongs to GitHub's URL, not to us — so an implementation that fixed the ticket by
      # editing the constant must fail here.
      #
      # The invariant over every size `1..MAX_BATCH` is pinned separately and deliberately
      # UNMODIFIED (see "keeps the emitted path within the byte bound at every batch size"); this is
      # the half that says the constant itself did not move.
      it "meets the byte bound without the bound having moved" do
        expect(GithubHelper::MAX_RETURN_TO_BYTES).to eq(1_500)
      end

      # Criterion 5. The session is where the GitHub credential lives, and it is a COOKIE session
      # with a 4KB ceiling — which is exactly why the batch is not stashed there. A hundred names is
      # ~2.6KB raw before encryption, and a near miss is worse than an overflow: it quietly evicts
      # the token instead of raising, breaking verification with nothing said anywhere.
      #
      # Asserted after a FULL round trip at MAX_BATCH, because a batch-sized cookie would survive
      # the summary render and only fail once the callback wrote the reconnected token beside it.
      it "leaves the session's GitHub credential intact across a full-size round trip" do
        names = batch(BulkRegistration::MAX_BATCH)
        submit_unauthorized(BulkRegistration::MAX_BATCH)

        state = carried_return_to(response.body, github_installation_authorize_path)

        allow(GithubAppUserAuthorization).to receive(:authorize).and_return(
          GithubAppUserAuthorization::Authorization.new(
            token: "ghu_reconnected", expires_at: 1.hour.from_now,
            installations: [GithubAppUserAuthorization::Installation.new(installation_id: 6001,
                                                                        account_login: "acme")]
          )
        )
        stub_github(repos: names.map { |name| github_repo(name) })

        get github_installation_callback_path, params: { code: "abc", state: state }
        follow_redirect!

        # Both keys present and READABLE — the token the callback just wrote, and its expiry. A
        # `CookieOverflow` would have raised before here; a near miss would have silently dropped
        # one of these two.
        expect(session[GithubUserSession::TOKEN_KEY]).to eq("ghu_reconnected")
        expect(session[GithubUserSession::EXPIRES_KEY]).to be_present
        # And the names are NOT in the cookie: they are the thing that would have overflowed it.
        expect(session.to_hash.to_s).not_to include(names.first)
      end
    end

    # SPGD-840. What a handle does when it does NOT name a live selection of this person's.
    #
    # Criterion 4. All of these degrade to the SAME place — the right account, an unticked list —
    # which is precisely what an over-bound batch delivered before handles existed. That is the
    # floor this change is built on: it never does worse than the behaviour it replaced.
    describe "redeeming a handle that names nothing" do
      def picker_with(token)
        stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])
        get bulk_repositories_path(organization: "acme", GithubHelper::SELECTION_PARAM => token)
      end

      def unticked_picker_for_acme
        expect(response).to have_http_status(:ok)
        picker = Capybara.string(response.body)
        # The right ACCOUNT — the half that is never dropped, and the whole of the degraded promise.
        expect(picker).to have_field(type: "checkbox", with: "acme/api", checked: false)
        expect(picker).to have_field(type: "checkbox", with: "acme/web", checked: false)
      end

      it "ticks nothing for a handle nobody minted" do
        picker_with("no-such-handle")

        unticked_picker_for_acme
      end

      it "ticks nothing for a handle that has expired mid-trip" do
        selection = PendingBulkSelection.capture(user: @user, organization: "acme",
                                                 full_names: %w[acme/api acme/web])
        selection.update!(captured_at: PendingBulkSelection::MAX_AGE.ago - 1.minute)

        picker_with(selection.token)

        unticked_picker_for_acme
      end

      # THE ONE THAT IS ABOUT SOMEBODY ELSE'S DATA, and it is asserted explicitly rather than being
      # left to the unknown-id case above — an implementation that resolved handles GLOBALLY would
      # pass every other example on this page and leak here.
      #
      # `acme/api` is deliberately a name BOTH people could plausibly hold, and it is on the listing
      # this reader is shown: if the scope were missing, the other person's selection would tick a
      # real row on this page and the leak would be visible as a tick. The control is the line below
      # it — the same handle DOES redeem for its owner — so this pins the SCOPE rather than passing
      # on a handle that redeems for nobody at all.
      it "ticks nothing for a handle belonging to somebody else" do
        other = create_user(github_uid: "2002", github_handle: "hubot")
        theirs = PendingBulkSelection.capture(user: other, organization: "acme",
                                              full_names: %w[acme/api acme/web])

        picker_with(theirs.token)

        unticked_picker_for_acme
        expect(PendingBulkSelection.redeem(user: other, token: theirs.token))
          .to match_array(%w[acme/api acme/web])
      end

      # Criterion 6. Nothing is trusted about a resolved name beyond deciding which rows START
      # ticked — the same rule `BulkRegistrationsController#new` already states about the names it
      # accepts in the query string, and the reason a handle is safe to hand out at all.
      #
      # A name the listing does not contain matches no row: it is not rendered, not registered, and
      # not reported. `BulkRegistration` re-verifies every name against GitHub on submit regardless.
      it "matches no row for a resolved name the listing does not contain" do
        selection = PendingBulkSelection.capture(user: @user, organization: "acme",
                                                 full_names: %w[acme/api acme/not-in-the-listing])

        picker_with(selection.token)

        picker = Capybara.string(response.body)
        # The name that IS in the listing ticks, so the redemption demonstrably happened...
        expect(picker).to have_field(type: "checkbox", with: "acme/api", checked: true)
        # ...and the one that is not simply has no row to tick.
        expect(picker).to have_no_field(type: "checkbox", with: "acme/not-in-the-listing")
      end
    end

    # SPGD-845. The other half of the example directly above — and they are deliberately two
    # examples rather than one, because they pin two DIFFERENT properties of the same state.
    #
    # That one pins SAFETY: a carried name the listing does not contain renders no field and
    # registers nothing. It asserts `have_no_field` and stops. This pins HONESTY: the reader is TOLD
    # the list they carried came back short. Safety was answered from the start; honesty was not
    # answered at all, and a page can have the first without the second — which is exactly the state
    # this describe block was written against. A reader who ticked five, went to GitHub, added three
    # and came back saw three ticks, no row for the other two, and not one word about it.
    #
    # ## What these examples are really guarding, after round 1
    #
    # The first attempt reported the shortfall as ONE fact — "carried minus what has a row" worded
    # as "still not connected to the App, add it on GitHub". That is a false statement in three of
    # the four states that reach it, because `administered` is narrowed by two independent gates
    # (in the installation AND `admin?`) and is contingent on the reading having been COMPLETE.
    # So the examples below are organised BY BUCKET rather than by criterion, and the negative ones
    # — the three that assert the "not connected" claim is NOT made — are the load-bearing half.
    # They encode the rule `InstallationRepositories#name_verdict` already enforces server-side:
    # "Absent from a COMPLETE reading is GitHub's own answer. Absent from an incomplete one is our
    # page walk's or a broken installation's, and those must not read the same."
    describe "reporting a carried selection that came back short" do
      # The listing is the same two repositories throughout, so what varies between these examples
      # is only what was CARRIED — which is the variable the sentence is supposed to key on.
      def picker_carrying(names, organization: "acme")
        stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])
        get bulk_repositories_path(organization: organization, github_full_names: names)
      end

      # The four load-bearing phrases, one per bucket, in one place. Methods rather than constants:
      # a constant assigned inside a block takes the FILE's lexical scope, not the example group's,
      # so it would land on `Object` and be visible to every other spec in the suite.
      #
      # `absent_claim` is the one that must be withheld wherever the evidence does not support it,
      # and it is deliberately the SUBSTRING that carries the claim rather than a whole sentence —
      # a test that matched the full sentence would pass against a reworded false one.
      def absent_claim = "still not connected to the SpecGuard GitHub App"
      def instruction = "Add it to the App on GitHub"
      def withheld_claim = "does not list you as an administrator"
      def unconfirmed_claim = "could not confirm"
      def capitalisation_claim = "listed under a different capitalisation"
      # The capitalisation bucket's INSTRUCTION, asserted apart from its claim because they can fail
      # independently: the round-2 defect was a true diagnosis carrying an instruction the page
      # could not offer, so a fix that reworded the claim while keeping the "tick" would pass an
      # assertion on the claim alone.
      def tick_instruction = "Tick the matching"

      # ── The bucket the ticket was filed for: GitHub's own answer, from a COMPLETE reading ──────

      # Criterion 3, and the case the ticket exists for: some of what came back has no row at all,
      # the reading was complete, so the absence IS GitHub's answer and may be reported as one. The
      # page NAMES those repositories rather than counting them, because the reader's next action is
      # specific to them — these are the ones to go back and add.
      it "names the carried repositories the listing does not contain" do
        picker_carrying(%w[acme/api acme/ledger acme/payments])

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(absent_claim)
        # Both absentees are named...
        expect(response.body).to include("acme/ledger")
        expect(response.body).to include("acme/payments")
        # ...and the sentence carries the action, not just the diagnosis.
        expect(response.body).to include("Add them to the App on GitHub")

        # The control, and the reason this is not merely asserting on a string: the name that IS in
        # the listing still ticks, so the carry demonstrably happened and the page is short by
        # exactly the two it says it is.
        picker = Capybara.string(response.body)
        expect(picker).to have_field(type: "checkbox", with: "acme/api", checked: true)
        expect(picker).to have_no_field(type: "checkbox", with: "acme/ledger")
        expect(picker).to have_no_field(type: "checkbox", with: "acme/payments")
      end

      # ── The three buckets that must NOT borrow that wording ────────────────────────────────────

      # THE TRANSIENT PATH, and the sharpest of the three because the reader has just been told the
      # opposite. This is the ordinary multi-installation shape the "carrying a transiently-failed
      # batch back to the picker" block above documents: one installation rate-limits, the summary
      # says "GitHub's rate limit has been reached. Try again in a few minutes", and offers "Try
      # these again" — which carries the failed names into this very seam.
      #
      # One click later, the limit not yet cleared (the ordinary case — the reader clicks straight
      # away), the picker must not tell them the repository is not connected and send them to GitHub
      # to add a repository that is already there. `sources.complete?` is false here, so the absence
      # is OURS, and the page says exactly that and INSTRUCTS NOTHING.
      it "does not claim a carried name is unconnected when the listing came back incomplete" do
        add_github_installation(@user, installation_id: 6002, account_login: "globex")
        stub_github_per_installation do |id|
          FakeGithubApi.new(**(id == 6002 ? { forbidden: :rate_limited } : { repos: [github_repo("acme/api")] }))
        end

        get bulk_repositories_path(organization: "acme", github_full_names: %w[acme/api acme/web])

        expect(response).to have_http_status(:ok)
        # The false claim, and the instruction that would send them to perform a no-op, are both
        # withheld — this is the assertion the round-1 implementation failed.
        expect(response.body).not_to include(absent_claim)
        expect(response.body).not_to include(instruction)
        # And the reader is still TOLD, which is the point of the feature: silence here would be the
        # very gap this ticket was filed to close, merely reached through a different door.
        expect(response.body).to include(unconfirmed_claim)
        expect(response.body).to include("acme/web")
      end

      # TRUNCATION reaches the same verdict by the other half of `complete?`, and it is worth its
      # own example because it fails through a DIFFERENT field: our own page walk stopping at
      # `MAX_PAGES` sets no error and leaves every installation "read", so a completeness check
      # wired only to the unread accounts sails straight past it. Nothing else on this branch of
      # `new.html.erb` renders an incompleteness warning either — the `github_listing_incomplete?`
      # block is on the chooser branch — so this reading is the only thing standing between a short
      # read and a confident false sentence.
      it "does not claim a carried name is unconnected when the listing was truncated" do
        stub_github(repos: [github_repo("acme/api")], truncated: true)

        get bulk_repositories_path(organization: "acme", github_full_names: %w[acme/api acme/web])

        expect(response.body).not_to include(absent_claim)
        expect(response.body).not_to include(instruction)
        expect(response.body).to include(unconfirmed_claim)
      end

      # THE SELF-CONTRADICTION CASE. A carried name the viewer can SEE but does not administer is
      # connected — it is in the installation — and it has no row only because `administered` gates
      # on `admin?`. Reporting it as "not connected" puts two sentences four lines apart in the same
      # header block saying opposite things about the same repository, which is precisely the
      # "sentence and checkboxes contradict each other on one page" failure this feature is built to
      # avoid, reached from the side of the sibling sentence it was modelled on.
      #
      # `InstallationRepositories` has already ruled on this exact wording, in its class comment:
      # `:not_administered` is told apart from `:not_in_installation` deliberately, because "it is
      # not in the installation" would be "a false statement to make to them".
      it "says a carried name it can see but not administer is connected, not missing" do
        stub_github(repos: [github_repo("acme/api"), github_repo("acme/web", admin: false)])

        get bulk_repositories_path(organization: "acme", github_full_names: %w[acme/api acme/web])

        # The sibling sentence counts it as CONNECTED...
        expect(response.body).to include("you do not administer")
        # ...so this one must not, in the same breath, call it unconnected.
        expect(response.body).not_to include(absent_claim)
        expect(response.body).not_to include(instruction)
        # What it says instead is true, names the repository the reader asked for — which the
        # counting sibling cannot do — and names the fix, which is a person rather than a page.
        expect(response.body).to include(withheld_claim)
        expect(response.body).to include("acme/web")
        expect(response.body).to include("Ask an administrator")
      end

      # ── Silence, where silence is correct ──────────────────────────────────────────────────────

      # Criterion 1. A carry in which EVERY name matched is not short, and a page that says so
      # anyway is crying wolf at the reader who did exactly what they were asked to.
      it "says nothing when every carried name matched a row" do
        picker_carrying(%w[acme/api acme/web])

        picker = Capybara.string(response.body)
        expect(picker).to have_field(type: "checkbox", with: "acme/api", checked: true)
        expect(picker).to have_field(type: "checkbox", with: "acme/web", checked: true)
        expect(response.body).not_to include(absent_claim)
        expect(response.body).not_to include(unconfirmed_claim)
      end

      # Criterion 2, and the condition the ticket warns hardest about getting wrong. The trigger is
      # "names were carried AND some matched no row" — NOT "some listing rows are missing". A picker
      # reached fresh took no trip and has no shortfall; a sentence there would be noise about
      # something that never happened.
      it "says nothing on a picker reached with no carried selection at all" do
        stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

        choose_organization("acme")

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(absent_claim)
      end

      # ...including when the listing is genuinely missing things. This is the same page state as
      # the example above from the LISTING's point of view and differs only in what was carried, so
      # a condition wired to the listing rather than to the carry passes that one and fails here.
      it "says nothing on a fresh picker even when repositories are withheld from the listing" do
        stub_github(repos: [github_repo("acme/api"),
                            github_repo("acme/locked-down", admin: false)])

        choose_organization("acme")

        # The listing IS short, and the page says so in its own words — the sibling sentence.
        expect(response.body).to include("you do not administer")
        # But nothing was carried, so there is no shortfall to report, and in particular the
        # per-name version of that same fact is not minted for a repository nobody asked about.
        expect(response.body).not_to include(absent_claim)
        expect(response.body).not_to include(withheld_claim)
      end

      # An already-registered repository is NOT a shortfall. It has a row, that row is rendered
      # disabled with a badge that says exactly what happened to it, and reporting it a second time
      # as "not connected" would be false twice over — it is connected, and it is listed.
      it "does not report a carried name whose row is present but already registered" do
        create_repository(user: @user, github_full_name: "acme/web")

        picker_carrying(%w[acme/api acme/web])

        expect(response.body).to include("Already registered")
        expect(response.body).not_to include(absent_claim)
      end

      # ── The same property, asked of the SPELLING that used to escape it ────────────────────────
      #
      # The example directly above carries names spelled exactly as the listing spells them, so the
      # property it asserts was only ever true case-sensitively: `missing` is the checkbox's
      # case-SENSITIVE subtraction, so `acme/web` never reached the buckets at all and the silence
      # above was free. The SAME repository carried as `Acme/API` did reach them, landed in the
      # capitalisation bucket, and was answered with "Tick the matching row below" — an instruction
      # naming a row that renders `disabled` because it is already registered.
      #
      # Two examples rather than one because the row is unclickable in two DIFFERENT ways, through
      # two different branches of the template, and an exclusion wired to `registerable` rather than
      # to the registration fact could pass either one alone.
      it "does not tell the reader to tick a row that is disabled because it is already registered" do
        create_repository(user: @user, github_full_name: "acme/api")

        # Spelled the way GitHub DISPLAYS it, which is an ordinary way for this to arrive: names are
        # carried case-preserved, so submitting `Acme/API`, adding it on GitHub, registering it and
        # returning to the picker on that same handle reaches exactly this state.
        picker_carrying(%w[Acme/API])

        picker = Capybara.string(response.body)
        # The row is there and the page has already accounted for it — with a badge, not a sentence.
        expect(picker).to have_field(type: "checkbox", with: "acme/api", disabled: true)
        expect(response.body).to include("Already registered")
        # So no clause claims a shortfall about it, and in particular none issues an instruction the
        # reader cannot carry out on a disabled row.
        expect(response.body).not_to include(capitalisation_claim)
        expect(response.body).not_to include(tick_instruction)
        expect(response.body).not_to include(absent_claim)
      end

      # THE HARDER SUB-STATE, and the one that reads worst: when EVERY administered repository is
      # registered, `registerable.empty?` swaps the whole list for the "Nothing left to register"
      # empty state and NO checkbox renders at all. The clause was printing "Tick the matching row
      # below" directly above a paragraph saying there is nothing left to do — two paragraphs, one
      # page, opposite instructions.
      it "does not tell the reader to tick a row when the picker has no rows left to offer" do
        create_repository(user: @user, github_full_name: "acme/api")
        create_repository(user: @user, github_full_name: "acme/web")

        picker_carrying(%w[Acme/API])

        # The page is in its empty state — this is the branch that renders no fields at all, so the
        # assertions below are about a page with nothing to tick rather than a merely disabled row.
        expect(response.body).to include("Nothing left to register")
        expect(Capybara.string(response.body)).to have_no_field(type: "checkbox", with: "acme/api")
        expect(response.body).not_to include(capitalisation_claim)
        expect(response.body).not_to include(tick_instruction)
      end

      # The capitalisation bucket is not the only one an already-registered name could reach, so the
      # exclusion is done BEFORE the partition rather than inside that one clause. A repository
      # somebody else registered can be visible-but-not-administered by this reader, which lands in
      # the withheld bucket — "ask an administrator of that repository to register it", about a
      # repository that is already registered. That instruction is wrong in the same way: it asks
      # for work that is already done.
      it "does not ask for an administrator to register a repository that is already registered" do
        other = create_user(github_uid: "3003", github_handle: "octocat")
        create_repository(user: other, github_full_name: "acme/web")
        stub_github(repos: [github_repo("acme/api"), github_repo("acme/web", admin: false)])

        get bulk_repositories_path(organization: "acme", github_full_names: %w[acme/web])

        expect(response).to have_http_status(:ok)
        # The listing is still short and still says so in its own counting words — the sibling
        # sentence is untouched, which is what makes this about the per-name clause and not about
        # suppressing the page's honesty generally.
        expect(response.body).to include("you do not administer")
        # But the per-name clause does not ask for a registration that has already happened.
        expect(response.body).not_to include(withheld_claim)
        expect(response.body).not_to include("Ask an administrator")
        expect(response.body).not_to include(absent_claim)
      end

      # A carried name belonging to some OTHER account is not this page's to rule on. Every row here
      # is `acme`'s, and `visible` is `acme`'s slice of the listing, so a `globex` name is not
      # absent from GitHub — it is absent from the page the reader happens to be standing on. The
      # picker builds every batch from one account, so this is a hand-made request rather than an
      # ordinary path; the property is that it cannot produce a false sentence when it happens.
      it "says nothing about a carried name belonging to a different account" do
        stub_github(repos: [github_repo("acme/api"), github_repo("globex/thing")])

        get bulk_repositories_path(organization: "acme",
                                   github_full_names: %w[acme/api globex/thing])

        expect(Capybara.string(response.body))
          .to have_field(type: "checkbox", with: "acme/api", checked: true)
        expect(response.body).not_to include(absent_claim)
        expect(response.body).not_to include(withheld_claim)
      end

      # ── The comparison, and the seams ──────────────────────────────────────────────────────────

      # Criterion 4. THE ONE THAT PINS THE COMPARISON, and it is a real divergence rather than a
      # hypothetical: `BulkRegistration.normalized_names` de-duplicates with `uniq(&:downcase)` but
      # PRESERVES each name's original case, and `Repository.normalize_full_name` does not downcase
      # either — so a carried `Acme/API` reaches the template spelled exactly that way.
      #
      # The checkbox asks `@full_names.include?(repo.full_name)` — case-SENSITIVE — so that name
      # does not tick today. WHICH name failed to tick is therefore asked in the checkbox's own
      # words, and a subtraction written case-INSENSITIVELY would call it matched and stay silent,
      # leaving the reader with an unticked row the page insists is fine.
      #
      # WHY it failed is a different question and takes the opposite comparison — every layer that
      # resolves a repository does so case-insensitively (`name_verdict`'s `seen[name.downcase]`,
      # `dedupe`, `GithubOrganizations.find`'s `casecmp?`) — and that is what earns this name the
      # TRUE sentence rather than the false one. It is listed; it is not unconnected. Both halves
      # are asserted here because it is their disagreement this example exists to make impossible.
      it "reports a carried name that differs from a listing row only by case, and does not tick it" do
        picker_carrying(%w[Acme/API])

        picker = Capybara.string(response.body)
        # The row is there, spelled the listing's way, and it is NOT ticked...
        expect(picker).to have_field(type: "checkbox", with: "acme/api", checked: false)
        # ...and the page says so, naming the carried spelling the reader would recognise AND the
        # listed one they have to tick.
        expect(response.body).to include(capitalisation_claim)
        expect(response.body).to include("Acme/API")
        expect(response.body).to include("acme/api")
        # It is listed, so the claim that it is not connected would be false — this is the assertion
        # that distinguishes a correct report from a merely present one.
        expect(response.body).not_to include(absent_claim)
      end

      # Criterion 5. The subtraction is over things `#new` already had in hand, so it costs nothing
      # at the boundary — including the two readings added in round 2 (`organization.repos` and the
      # completeness check), which come off the same memoized sources the page already read.
      # Asserted as a COMPARISON against the same page rendered without a carry, rather than against
      # a hard-coded number: what matters is that carrying a short selection adds no read, and a
      # literal would silently re-pass if the page's own listing read changed underneath it.
      it "asks GitHub no more times than the same picker rendered with nothing carried" do
        fake = stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

        # What the page costs with NOTHING carried — the control.
        choose_organization("acme")
        baseline = fake.calls_to(:repositories)
        # Guards the comparison against being vacuous: if the picker read nothing at all, the
        # equality below would hold at zero no matter what the carried render did.
        expect(baseline).to be_positive

        before_carry = fake.calls_to(:repositories)
        get bulk_repositories_path(organization: "acme",
                                   github_full_names: %w[acme/api acme/ledger acme/payments])
        carried_reads = fake.calls_to(:repositories) - before_carry

        expect(response.body).to include(absent_claim)
        expect(carried_reads).to eq(baseline)
      end

      # The handle leg reaches the identical seam — `submitted_full_names + redeemed_full_names`
      # feed one `@full_names` and the picker "never learns which of the two they were ticked by"
      # — so the sentence must not learn either. This is the leg the summary's three FIX buttons
      # actually use, and the `not_in_installation` button carries, by construction, precisely the
      # names that cannot tick until GitHub's own picker is changed.
      it "reports the shortfall for a selection carried by handle, not only by query string" do
        selection = PendingBulkSelection.capture(user: @user, organization: "acme",
                                                 full_names: %w[acme/api acme/ledger])

        stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])
        get bulk_repositories_path(organization: "acme",
                                   GithubHelper::SELECTION_PARAM => selection.token)

        expect(response.body).to include(absent_claim)
        expect(response.body).to include("acme/ledger")
        expect(Capybara.string(response.body))
          .to have_field(type: "checkbox", with: "acme/api", checked: true)
      end
    end

    # The helper under the two buttons, asked directly. The bound examples above are about SIZE
    # rather than about rendering, and driving them through a full POST per batch size would be 100
    # registrations to measure a string.
    #
    # A bare context including the two modules the method actually needs, rather than
    # `ApplicationController.helpers`: that proxy is an `ActionView::Base` without the route helpers
    # mixed in, so `bulk_repositories_path` is undefined on it.
    def helper_return_to(names, organization: "acme")
      helper_context.bulk_picker_return_to(organization: organization, full_names: names)
    end

    def helper_context
      @helper_context ||= Class.new do
        include Rails.application.routes.url_helpers
        include GithubHelper
      end.new
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

  # SPGD-806 — the tokens on the summary.
  #
  # This is the layer the service spec cannot reach: `BulkRegistration` can be asked whether it
  # minted a key, but whether the PLAINTEXT actually reaches the page — and whether the page is kept
  # out of Turbo's snapshot cache while it holds N of them — is a question about the render.
  #
  # No flash is involved anywhere in here, and that is the design rather than an omission. `#create`
  # renders its summary instead of redirecting, and `ApiKey` holds the plaintext for exactly the
  # request that minted it, so the tokens are simply present in the response that created them.
  describe "the first API key of each newly registered repository" do
    it "shows one distinct plaintext token per newly registered repository" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"), github_repo("acme/cli")])

      submit(%w[acme/api acme/web acme/cli])

      tokens = ApiKey.all.map { |key| key.repository.github_full_name }
      expect(tokens).to match_array(%w[acme/api acme/web acme/cli])

      shown = response.body.scan(/sgk_[A-Za-z0-9_-]+/).uniq
      expect(shown.length).to eq(3)
    end

    # The keys are minted for the person who submitted the batch, and attribution has no second
    # chance — `ApiKeysController#destroy` is a hard `destroy!` with no audit row, so a key minted
    # NULL is NULL forever.
    it "records the submitting user as the creator of every key" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      submit(%w[acme/api acme/web])

      expect(ApiKey.pluck(:created_by_user_id)).to all(eq(@user.id))
    end

    # Criterion 6, first half. Without this meta Turbo snapshots the live DOM — every plaintext
    # token on it — when the reader navigates away, and repaints it on Back, which would make the
    # page's "only time these are shown" claim false. It is a PAGE-level decision, so it is emitted
    # once however many tokens the batch produced.
    it "emits exactly one no-cache meta when keys were minted" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"), github_repo("acme/cli")])

      submit(%w[acme/api acme/web acme/cli])

      expect(response.body.scan('name="turbo-cache-control"').length).to eq(1)
    end

    # Criterion 6, second half — and the half that says the meta is CONDITIONAL rather than always
    # on. A summary holding no tokens is an ordinary page, and suppressing the whole app's snapshot
    # cache for it would be a cost paid for nothing.
    it "emits no no-cache meta when the batch minted nothing" do
      create_repository(user: @user, github_full_name: "acme/api")
      stub_github(repos: [github_repo("acme/api")])

      submit(%w[acme/api])

      expect(ApiKey.count).to eq(0)
      expect(response.body).not_to include("turbo-cache-control")
    end

    # Criterion 8. `copy_text_controller.js` reads the SINGULAR `this.sourceTarget`, and Stimulus
    # resolves a target to its nearest same-identifier ancestor — so N tokens under ONE scope would
    # mean Copy and Download grabbing whichever came first, on a page whose entire job is getting
    # these values off it.
    #
    # Each row opens its own scope plus a nested one for the agent prompt (a second payload in the
    # row's scope would be what Copy grabbed), which is the same split `repositories/_revealed_token`
    # makes for the same reason. Three registered rows is therefore six scopes.
    it "gives every repository its own copy-text scope" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"), github_repo("acme/cli")])

      submit(%w[acme/api acme/web acme/cli])

      expect(response.body.scan('data-controller="copy-text"').length).to eq(6)
    end

    # Auto-copy is right for the single-repository reveal — one token, one clipboard — and WRONG
    # here: N blocks racing to write one clipboard on connect leaves the reader holding whichever
    # token won, which is worse than no auto-copy because it looks like it worked.
    it "never enables auto-copy on the batch summary" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      submit(%w[acme/api acme/web])

      expect(response.body).not_to include("copy-text-auto-copy-value")
    end

    # THE REFRESH HAZARD, criterion 2 — the highest-risk part of this change and the one that must
    # not be left implicit. The controller's header notes that a refresh re-submits and that this is
    # survivable because registration is idempotent. That stays true of the ROWS and is exactly what
    # is NOT true of the TOKENS: the re-submitted batch mints nothing, so the tokens are gone.
    #
    # So the page has to SAY so, and name the recovery — regenerating the key costs a rotation
    # rather than a re-registration, and a reader who does not know that may go looking for a way to
    # register the repository a second time.
    it "states the hazard and names regeneration as the recovery" do
      stub_github(repos: [github_repo("acme/api")])

      submit(%w[acme/api])

      expect(response.body).to include("Reloading this page will not bring them back")
      expect(response.body).to include("regenerate")
    end

    # The same hazard, DRIVEN rather than described: the identical batch submitted a second time.
    it "mints nothing on a re-submission and shows no token the second time" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"), github_repo("acme/cli")])

      submit(%w[acme/api acme/web acme/cli])
      first_tokens = response.body.scan(/sgk_[A-Za-z0-9_-]+/).uniq
      expect(first_tokens.length).to eq(3)

      expect { submit(%w[acme/api acme/web acme/cli]) }.not_to change(ApiKey, :count)

      expect(response.body).to include("Already registered (3)")
      expect(response.body).not_to match(/sgk_[A-Za-z0-9_-]+/)
      first_tokens.each { |token| expect(response.body).not_to include(token) }
    end

    # Criterion 3 at the render layer: an already-registered repository somebody ELSE owns must not
    # be handed a credential. The summary already refuses to link those rows, and this is the same
    # rule one step further — that repository may already hold keys, and it was not registered by
    # this batch.
    it "mints nothing for a repository somebody else already registered" do
      create_repository(user: create_user(github_uid: "9", github_handle: "someone"),
                        github_full_name: "acme/theirs")
      stub_github(repos: [github_repo("acme/theirs"), github_repo("acme/api")])

      expect { submit(%w[acme/theirs acme/api]) }.to change(ApiKey, :count).by(1)

      expect(ApiKey.last.repository.github_full_name).to eq("acme/api")
      expect(response.body.scan(/sgk_[A-Za-z0-9_-]+/).uniq.length).to eq(1)
    end

    # THE MINT FAILURE AT THE RENDER LAYER — non-negotiable (d)'s second half, and the example that
    # makes `Result#any_revealed?` load-bearing rather than merely argued for.
    #
    # `mint_first_key` rescues per candidate, so a batch can register rows and produce no tokens at
    # all. That is the state the summary has to render honestly, and it is a PAGE-level question the
    # service spec cannot ask: the service spec establishes that the outcome is `:registered` with
    # `api_key` nil, and this establishes what the page does with it.
    #
    # It is the "zero" case criterion 6 was otherwise missing. The example above it drives a batch
    # that registered NOTHING, which suppresses the apparatus under `any_registered?` too — so it
    # cannot tell the two questions apart. This one can: a page reasoning from `any_registered?`
    # emits the cache-suppressing meta, the "copy these before you leave" warning and a panel headed
    # "0 API keys — this is the only time they are shown" over an empty list. That render is the
    # failure mode, and this example is what sees it.
    it "shows no reveal apparatus when every registered row's mint failed" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])
      fail_the_mint_for("acme/api", "acme/web")
      allow(Rails.logger).to receive(:warn)

      submit(%w[acme/api acme/web])

      # The registrations themselves survived — that is the contract the rescue exists to keep, and
      # it is what makes the absence below a decision rather than a failed batch.
      expect(Repository.count).to eq(2)
      expect(ApiKey.count).to eq(0)
      expect(response.body).to include("Registered (2)")

      expect(response.body).not_to include("turbo-cache-control")
      expect(response.body).not_to include("this is the only time")
      expect(response.body).not_to include("Copy these before you leave this page")
      expect(response.body).not_to match(/sgk_[A-Za-z0-9_-]+/)
    end

    # The MIXED batch, which is the case that separates `any_revealed?` from a plain
    # `registered.length` anywhere the count is rendered. One row keeps its key and one loses it, so
    # the panel must be headed for ONE key rather than for the two rows that were registered, and
    # exactly one wire-up block may appear.
    #
    # Both rows still belong under "Registered (2)": the keyless one links to a repository that
    # really was registered, and it simply carries no wire-up block. A page that dropped it, or that
    # counted it among the revealed, would be lying in one direction or the other.
    it "reveals only the rows that kept a key, and still lists the one that did not" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])
      fail_the_mint_for("acme/web")
      allow(Rails.logger).to receive(:warn)

      submit(%w[acme/api acme/web])

      expect(ApiKey.count).to eq(1)
      expect(response.body).to include("Registered (2)")
      expect(response.body).to include("1 API key — this is the only time it is shown")
      expect(response.body.scan(/sgk_[A-Za-z0-9_-]+/).uniq.length).to eq(1)
      expect(response.body.scan("Repository:  acme/api").length).to eq(1)
      expect(response.body).not_to include("Repository:  acme/web")
    end

    # The wire-up prompt carries THIS repository's own name and THIS repository's own token, which
    # is the property that makes it paste-ready. `integration_guide_agent_prompt` already takes
    # `repository:` as an argument, so it works per row unchanged.
    it "gives each repository a prompt naming it, with its own token already in it" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      submit(%w[acme/api acme/web])

      expect(response.body.scan("Wire this repository up").length).to eq(2)
      expect(response.body.scan("Repository:  acme/api").length).to eq(1)
      expect(response.body.scan("Repository:  acme/web").length).to eq(1)
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
