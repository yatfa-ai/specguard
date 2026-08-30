# frozen_string_literal: true

require "rails_helper"

# The squatting gap, and its closing.
#
# Before this, `RepositoriesController#create` performed no ownership check of any kind: any
# signed-in user could POST any `org/repo` that was not already taken and become its owner here.
# Because `github_full_name` is globally unique, claiming a slug also locked its real owner out.
#
# The gap had two doors, not one — `repository_params` is shared by `#create` and `#update` — so
# every example below that pins the create path has a rename twin. A guard on one action only would
# have moved the gap one route over and read as closed.
#
# What ANSWERS the question changed with SPGD-424 and the gap did not reopen. It was
# `permissions.admin` read over an OAuth `repo` grant — GitHub's full control of private
# repositories, asked for in order to read one boolean. It is now TWO conditions read from one
# response to `GET /user/installations/:id/repositories`, made with the user's own short-lived
# credential: the repository is in one of this user's App installations, AND GitHub reports this
# user as an administrator of it.
#
# Both are load-bearing and each has its own example below. Installation membership alone is not
# enough, because GitHub shows an organization's installation to every member of that organization
# — so a read-only member could otherwise register everything their employer connected. The admin
# bar is the same bar the OAuth path had, now bought with Metadata: read-only instead.
RSpec.describe "Installation-verified repository registration", type: :request do
  before { @user = sign_in_via_github }

  def register(full_name)
    post repositories_path, params: { repository: { github_full_name: full_name } }
  end

  describe "POST /repositories" do
    # @intent: {"entity": "POST /repositories", "action": "register covered repository", "behavior": "posting acme/billing-service from the covered installation creates one Repository owned by the signer, redirects to its show page, and makes exactly one GitHub repositories call", "layer": "request"}
    it "registers a repository the installation covers" do
      fake = stub_github(repos: [github_repo("acme/billing-service")])

      expect { register("acme/billing-service") }.to change(Repository, :count).by(1)

      expect(response).to redirect_to(repository_path(Repository.last))
      expect(Repository.last.user).to eq(@user)
      # One GitHub read for the whole registration. The listing IS the verification, so there is no
      # second question to ask.
      expect(fake.calls_to(:repositories)).to eq(1)
    end

    # THE example. Somebody else's repository, named directly at the endpoint, bypassing the picker
    # entirely — which is exactly what a squatter would do. It is not in this user's installation,
    # so there is nothing for them to register.
    # @intent: {"entity": "POST /repositories", "action": "refuse uncovered repository", "behavior": "posting someone-else/private-repo creates no Repository row and is answered 422 with the not-one-of-the-repositories-the-App-is-installed-on sentence", "layer": "request"}
    it "refuses a repository outside the user's installation" do
      stub_github(repos: [github_repo("acme/billing-service")])

      expect { register("someone-else/private-repo") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not one of the repositories the SpecGuard GitHub App is installed on")
    end

    # THE OTHER example, and the one this file did not have when the gap was reopened. The
    # repository IS in the installation — somebody who administers it did connect it — and this
    # user is not that somebody. That is the position of every read-only member of every
    # organization that installs the App, and under an installation-token read they could register
    # all of it.
    # @intent: {"entity": "POST /repositories", "action": "refuse unadministered repository", "behavior": "posting acme/vault, which the installation covers but this user does not administer, creates no row and is answered 422 with the does-not-list-you-as-an-administrator sentence", "layer": "request"}
    it "refuses a repository in the installation that this user does not administer" do
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/vault", admin: false)])

      expect { register("acme/vault") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("does not list you as an administrator")
    end

    # And it is not merely refused at the write — it is never offered. The picker and the gate are
    # built from the same object, so a page cannot show something the POST would turn down.
    # @intent: {"entity": "GET /repositories/new", "action": "withhold unadministered option", "behavior": "the picker body includes acme/billing-service and omits acme/vault, the covered repository this user cannot administer", "layer": "request"}
    it "does not offer a repository this user only has read access to" do
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/vault", admin: false)])

      get new_repository_path

      expect(response.body).to include("acme/billing-service")
      expect(response.body).not_to include("acme/vault")
    end

    # "Does not exist" and "exists and is not yours" are ONE answer from this credential,
    # which cannot see outside its own installation — and that is a feature rather than a loss of
    # detail: the old path told a stranger whether a private repository existed by answering
    # `:not_found` for an invented name and `:not_admin` for a real one.
    # @intent: {"entity": "POST /repositories", "action": "refuse unknown repository", "behavior": "posting ghost/repo against an empty listing creates no row and returns 422 with the same installed-on sentence used for a repository outside the installation", "layer": "request"}
    it "refuses a repository GitHub has never heard of, in the same words" do
      stub_github(repos: [])

      expect { register("ghost/repo") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not one of the repositories the SpecGuard GitHub App is installed on")
    end

    # Fails closed. If an outage were treated as a pass, the gap would reopen on every GitHub 500 —
    # which is a worse property than the one being fixed, because it is intermittent.
    # @intent: {"entity": "POST /repositories", "action": "fail closed on outage", "behavior": "with GitHub unavailable the post creates no row and is answered 422 with the could-not-read-your-full-repository-list message", "layer": "request"}
    it "refuses to register anything while GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("could not read your full repository list")
    end

    # @intent: {"entity": "POST /repositories", "action": "demand app install", "behavior": "with the App uninstalled the post creates no row and the 422 body offers Connect your GitHub repositories", "layer": "request"}
    it "refuses when the App is not installed, and offers to install it" do
      uninstall_github_app(@user)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Connect your GitHub repositories")
    end

    # The install button on a 422 has to come back to the form, and the form is a GET the user is
    # no longer on: `request.fullpath` here is `/repositories`, the POST path, which renders the
    # index. A user who submits, is told to connect GitHub, and installs the App would land on the
    # dashboard and have to find "Register" again — on the one path they are most likely to press
    # the button.
    # @intent: {"entity": "POST /repositories", "action": "return to form after install", "behavior": "the 422 install prompt carries return_to pointing at the new-repository form path, not the /repositories index the POST ran on", "layer": "request"}
    it "returns the user to the registration form after installing from a failed registration" do
      allow(SpecGuard::GithubApp).to receive_messages(configured?: true, slug: "specguard")
      uninstall_github_app(@user)

      register("acme/billing-service")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML("return_to=#{CGI.escape(new_repository_path)}"))
      expect(response.body).not_to include(CGI.escapeHTML("return_to=#{CGI.escape(repositories_path)}\""))
    end

    # GitHub refusing is not GitHub being down, and it is not something the user can fix by
    # installing again either — so it is reported rather than dressed up as a retry or as a button.
    # @intent: {"entity": "POST /repositories", "action": "report GitHub refusal", "behavior": "a GitHub 403 refusal registers nothing and is answered 422 with the could-not-read-your-full-repository-list message rather than an install prompt", "layer": "request"}
    it "reports a refusal without telling the user to wait it out" do
      stub_github(forbidden: :refused)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("could not read your full repository list")
    end

    # @intent: {"entity": "POST /repositories", "action": "name the rate limit", "behavior": "a rate-limited 403 registers nothing and the 422 body includes the words rate limit while omitting GitHub did not answer", "layer": "request"}
    it "names the rate limit rather than reporting it as an outage" do
      stub_github(forbidden: :rate_limited)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("rate limit")
      expect(response.body).not_to include("GitHub did not answer")
    end

    # Shape and uniqueness are the record's own rules and settle the answer before GitHub's does.
    # The discriminator is the SENTENCE rather than a round-trip count: verification now reads the
    # same listing the picker is built from, so an extra question costs no extra request and a
    # counter could not tell the two orders apart.
    # @intent: {"entity": "POST /repositories", "action": "reject malformed name", "behavior": "posting nonsense is answered 422 with the must-look-like-org/repo message and not the installed-on sentence, settling shape before GitHub is asked", "layer": "request"}
    it "refuses a name that is not org/repo on the record's own rules" do
      stub_github

      register("nonsense")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must look like org/repo")
      expect(response.body).not_to include("is not one of the repositories")
    end

    # `valid?` runs `normalize_full_name`, so what is checked against the installation is the value
    # that would actually be STORED rather than whatever was pasted. A URL whose normalized form is
    # in the installation registers; one whose normalized form is not, does not.
    # @intent: {"entity": "POST /repositories", "action": "verify normalized name", "behavior": "pasting the full github.com URL of a covered repository redirects to the show page with the stored github_full_name normalized to acme/billing-service", "layer": "request"}
    it "checks the normalized name against the installation, not the pasted one" do
      stub_github(repos: [github_repo("acme/billing-service")])

      register("https://github.com/acme/billing-service")

      expect(response).to redirect_to(repository_path(Repository.last))
      expect(Repository.last.github_full_name).to eq("acme/billing-service")
    end

    # @intent: {"entity": "POST /repositories", "action": "refuse foreign URL", "behavior": "pasting a github.com URL whose normalized name falls outside the installation creates no row and is answered 422", "layer": "request"}
    it "refuses a pasted URL whose normalized name is outside the installation" do
      stub_github(repos: [github_repo("acme/billing-service")])

      expect { register("https://github.com/someone-else/thing.git") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # The sibling writer. `#update` is owner-only, but owning the SpecGuard *record* is exactly what
  # a squatter has — so "owner-only" was never an ownership check.
  describe "PATCH /repositories/:id" do
    let(:repository) { create_repository(user: @user, github_full_name: "acme/billing-service") }

    def rename(full_name)
      patch repository_path(repository), params: { repository: { github_full_name: full_name } }
    end

    # @intent: {"entity": "PATCH /repositories/:id", "action": "refuse foreign rename", "behavior": "renaming onto someone-else/private-repo is answered 422 and the record still reads acme/billing-service after reload", "layer": "request"}
    it "refuses to rename onto a repository outside the installation" do
      stub_github(repos: [github_repo("acme/billing-service")])

      rename("someone-else/private-repo")

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    # @intent: {"entity": "PATCH /repositories/:id", "action": "refuse unknown rename", "behavior": "renaming onto ghost/repo, which the empty listing has never heard of, is answered 422 and the stored name is unchanged", "layer": "request"}
    it "refuses to rename onto a repository GitHub cannot see" do
      stub_github(repos: [])

      rename("ghost/repo")

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    # @intent: {"entity": "PATCH /repositories/:id", "action": "rename within installation", "behavior": "renaming onto acme/checkout from the covered installation redirects to the show page with github_full_name reloaded as acme/checkout", "layer": "request"}
    it "renames onto another repository in the installation" do
      stub_github(repos: [github_repo("acme/checkout")])

      rename("acme/checkout")

      expect(response).to redirect_to(repository_path(repository))
      expect(repository.reload.github_full_name).to eq("acme/checkout")
    end

    # An unchanged submit changes no identity, so there is nothing to verify — and, just as
    # importantly, it must not start failing during a GitHub outage for a write that does nothing.
    # @intent: {"entity": "PATCH /repositories/:id", "action": "skip verification when unchanged", "behavior": "submitting the unchanged name redirects to the show page while the unavailable GitHub fake records zero repositories calls", "layer": "request"}
    it "does not ask GitHub when the submitted name is unchanged" do
      fake = stub_github(unavailable: true)

      rename("acme/billing-service")

      expect(response).to redirect_to(repository_path(repository))
      expect(fake.calls_to(:repositories)).to eq(0)
    end

    # The create path's twin: here `request.fullpath` is `/repositories/:id`, the PATCH path, which
    # renders the show page rather than the rename form.
    # @intent: {"entity": "PATCH /repositories/:id", "action": "return to rename form", "behavior": "the 422 install prompt carries return_to pointing at the edit form for the repository rather than the PATCH path that rendered it", "layer": "request"}
    it "returns the user to the rename form after installing from a failed rename" do
      allow(SpecGuard::GithubApp).to receive_messages(configured?: true, slug: "specguard")
      uninstall_github_app(@user)

      rename("acme/checkout")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body)
        .to include(CGI.escapeHTML("return_to=#{CGI.escape(edit_repository_path(repository))}"))
    end

    # The create path's twin: an outage must not let a rename through either, because the rename
    # form writes the same identity column the registration form does.
    # @intent: {"entity": "PATCH /repositories/:id", "action": "fail closed on rename", "behavior": "with GitHub unavailable the rename is answered 422, the stored name stays acme/billing-service, and the body carries the could-not-read message", "layer": "request"}
    it "refuses to rename anything while GitHub cannot be reached" do
      stub_github(unavailable: true)

      rename("acme/checkout")

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
      expect(response.body).to include("could not read your full repository list")
    end
  end

  describe "GET /repositories/new" do
    # @intent: {"entity": "GET /repositories/new", "action": "render picker", "behavior": "the form renders a select offering acme/billing-service and acme/checkout with no free-text org/repo placeholder field", "layer": "request"}
    it "offers the installation's repositories as a list rather than a free-text field" do
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/checkout")])

      get new_repository_path

      expect(response.body).to include("<select")
      expect(response.body).to include("acme/billing-service")
      expect(response.body).to include("acme/checkout")
      # The field that made squatting a matter of typing.
      expect(response.body).not_to include('placeholder="org/repo"')
    end

    # Nothing is withheld here, and the picker says where the list comes from instead of
    # apologising for its length.
    # @intent: {"entity": "GET /repositories/new", "action": "state list provenance", "behavior": "both covered repositories appear with the sentence naming the SpecGuard GitHub App as the list's source and no you-do-not-administer apology", "layer": "request"}
    it "offers everything in the installation, and says where the list comes from" do
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/checkout")])

      get new_repository_path

      expect(response.body).to include("acme/billing-service")
      expect(response.body).to include("acme/checkout")
      expect(response.body).to include("These are the repositories the SpecGuard GitHub App is installed on")
      expect(response.body).not_to include("you do not administer")
    end

    # And when something IS withheld the picker accounts for it. This is the ordinary position of a
    # read-only member of an organization that installed the App: the repository they came looking
    # for is genuinely connected, and is genuinely not theirs to register — two facts a bare short
    # list cannot tell them apart from a broken page.
    # @intent: {"entity": "GET /repositories/new", "action": "count withheld repositories", "behavior": "the administered acme/billing-service is offered, acme/legacy is omitted, and the page states that 2 connected repositories you do not administer are not listed", "layer": "request"}
    it "counts the connected repositories the viewer may not register" do
      stub_github(repos: [github_repo("acme/billing-service"),
                          github_repo("acme/legacy", admin: false),
                          github_repo("acme/vault", admin: false)])

      get new_repository_path

      expect(response.body).to include("acme/billing-service")
      expect(response.body).not_to include("acme/legacy")
      expect(response.body).to include("2 connected repositories you do not administer are not listed.")
    end

    # @intent: {"entity": "GET /repositories/new", "action": "mark private repository", "behavior": "the option for the private acme/secrets repository renders with the suffix private", "layer": "request"}
    it "marks a private repository as private in the list" do
      stub_github(repos: [github_repo("acme/secrets", private: true)])

      get new_repository_path

      expect(response.body).to include("acme/secrets · private")
    end

    # The other half of the note. `archived` changes what registering means as much as `private`
    # does — an archived repository will never push another CI run — so it has to be readable on
    # the option rather than discoverable after registering.
    # @intent: {"entity": "GET /repositories/new", "action": "mark archived repository", "behavior": "the option for acme/legacy-tracker renders with the suffix archived", "layer": "request"}
    it "marks an archived repository as archived in the list" do
      stub_github(repos: [github_repo("acme/legacy-tracker", archived: true)])

      get new_repository_path

      expect(response.body).to include("acme/legacy-tracker · archived")
    end

    # Both notes at once, asserted with the join intact: the label is one `·` and then a
    # comma-joined list, not two separate `·` groups, and the order is private-then-archived.
    # @intent: {"entity": "GET /repositories/new", "action": "mark private and archived", "behavior": "a repository both private and archived renders one middot separator then private, archived in that order", "layer": "request"}
    it "marks a repository that is both private and archived with both notes" do
      stub_github(repos: [github_repo("acme/vault", private: true, archived: true)])

      get new_repository_path

      expect(response.body).to include("acme/vault · private, archived")
    end

    # The third sentence of the hint, which only appears when GitHub's listing hit the page walk's
    # ceiling. The figure is re-derived from the two constants that produce it rather than written
    # as `1000`: a literal here would keep reading green after a change to either constant while
    # the page told the user a capacity the client no longer has.
    # @intent: {"entity": "GET /repositories/new", "action": "disclose listing cap", "behavior": "a truncated listing prints Showing the first followed by the GithubApi MAX_PAGES times PER_PAGE figure, matching the walk capacity the client actually has", "layer": "request"}
    it "says the listing was capped, at the capacity the client actually walks" do
      stub_github(truncated: true)

      get new_repository_path

      expect(response.body).to include(
        "Showing the first #{GithubApi::MAX_PAGES * GithubApi::PER_PAGE} repositories GitHub returned."
      )
    end

    # @intent: {"entity": "GET /repositories/new", "action": "stay silent when uncapped", "behavior": "an untruncated listing renders no Showing-the-first sentence at all", "layer": "request"}
    it "does not claim the listing was capped when it was not" do
      stub_github

      get new_repository_path

      expect(response.body).not_to include("Showing the first")
    end

    # @intent: {"entity": "GET /repositories/new", "action": "ask for installation", "behavior": "with nothing connected the page shows Connect your GitHub repositories, explains the App, and renders no select", "layer": "request"}
    it "asks for the installation instead of a picker when nothing is connected yet" do
      uninstall_github_app(@user)

      get new_repository_path

      expect(response.body).to include("Connect your GitHub repositories")
      expect(response.body).to include("SpecGuard connects repositories through a GitHub App")
      expect(response.body).not_to include("<select")
    end

    # The install branch is asked first and has to keep winning over the reconnect one, including
    # when a listing read WOULD come back `:not_authorized`: a user with nothing installed cannot
    # fix anything by reconnecting. And the page settles it without asking GitHub at all, which is
    # the reason `github_installation_needed?` reads our own table rather than the sources.
    # @intent: {"entity": "GET /repositories/new", "action": "settle install before reconnect", "behavior": "with nothing connected and the token rejected the page still offers the install prompt, never Reconnect to GitHub, and makes zero repositories calls", "layer": "request"}
    it "offers the installation without calling GitHub when nothing is connected and the token is rejected" do
      uninstall_github_app(@user)
      fake = stub_github(unauthorized: true)

      get new_repository_path

      expect(response.body).to include("Connect your GitHub repositories")
      expect(response.body).not_to include("Reconnect to GitHub")
      expect(fake.calls_to(:repositories)).to eq(0)
    end

    # Installed, and covering nothing — the user completed the flow and selected no repositories, or
    # has since deselected them all. Distinct from "not installed": installing again would do
    # nothing, and the fix is choosing repositories on GitHub.
    # @intent: {"entity": "GET /repositories/new", "action": "distinguish empty installation", "behavior": "an installed App covering no repositories shows the No repositories connected yet panel instead of a picker", "layer": "request"}
    it "distinguishes an installation that covers nothing from no installation at all" do
      stub_github(repos: [])

      get new_repository_path

      expect(response.body).to include("No repositories connected yet")
      expect(response.body).not_to include("<select")
    end

    # And a THIRD empty page, which is not the one above: the installation covers plenty and this
    # viewer administers none of it. "No repositories connected yet" would be a false statement to
    # make to them, and the button it carries goes to a picker that would fix nothing — the thing in
    # their way is somebody else's admin rights.
    # @intent: {"entity": "GET /repositories/new", "action": "distinguish unadministered coverage", "behavior": "an installation whose two repositories this viewer cannot administer shows Nothing here is yours to register with the count of 2, not the nothing-connected panel or a select", "layer": "request"}
    it "distinguishes an installation that covers nothing this viewer administers" do
      stub_github(repos: [github_repo("acme/api", admin: false),
                          github_repo("acme/web", admin: false)])

      get new_repository_path

      expect(response.body).to include("Nothing here is yours to register")
      expect(response.body).to include("2 connected repositories you do not administer are not listed.")
      expect(response.body).not_to include("No repositories connected yet")
      expect(response.body).not_to include("<select")
    end

    # THE case this page was silent in, and the population none of the notice's own examples reach:
    # every one of them stubs an admin repository for the healthy installation, so a list renders and
    # the notice sits above it. Here there is NO list — and an unreadable account is the likeliest
    # reason for that rather than an unrelated aside, because a 404'd installation contributes zero
    # registrable repositories by construction.
    #
    # The SOLE-installation shape: the user's only installation was uninstalled on GitHub. There is
    # no webhook and no uninstall cleanup in this codebase, so the local row survives forever and
    # this is the steady state rather than a blip. `read` returns an EMPTY listing and `:unreadable`
    # for it, so `error` stays nil and `complete?` stays true — which is why the page could reach the
    # "you selected nothing" panel and say a sentence about an installation that does not exist.
    # @intent: {"entity": "GET /repositories/new", "action": "name missing installation", "behavior": "when the sole installation 404s the page says GitHub no longer lists acme as connected to SpecGuard, dropping both the nothing-connected sentence and the no-repositories-selected one", "layer": "request"}
    it "names the sole installation GitHub no longer lists rather than blaming the selection" do
      stub_github(not_found: true)

      get new_repository_path

      expect(response.body).to include("GitHub no longer lists acme as connected to SpecGuard")
      # The false sentence, pinned by its own words rather than only by its title: the App is NOT
      # installed on that account any more, so "no repositories are selected for it" describes an
      # installation GitHub 404s, and the button under it went to a picker for the same.
      expect(response.body).not_to include("No repositories connected yet")
      expect(response.body).not_to include("no repositories are selected for it")
    end

    # The closing clause is the half of the sentence that cannot be shared with the picker's notice.
    # "Anything shown here can still be registered" is an offer about what is on the page, and this
    # page is showing nothing — so an empty-state branch that reused the picker's wording would name
    # the account correctly and then close with a claim about a list that is not there.
    # @intent: {"entity": "GET /repositories/new", "action": "hedge empty page", "behavior": "the empty page explains it may be empty because an account could not be listed, and never closes with the anything-shown-here offer about a list that is not there", "layer": "request"}
    it "does not close an empty page by offering what it is not showing" do
      stub_github(not_found: true)

      get new_repository_path

      expect(response.body).to include("could not be listed, so this page may be empty for that " \
                                       "reason rather than because there is nothing to register")
      expect(response.body).not_to include("Anything shown here can still be registered")
    end

    # The OTHER reachable empty shape, and it needs its own example because it renders a different
    # panel through a different branch: one installation answers with repositories this viewer does
    # not administer (so `withheld_count` is positive and the "ask an administrator" panel wins),
    # while a second 404s. The advice is about repositories this page CAN see, and without the notice
    # it sends the reader to ask an administrator about an account nobody can read at all.
    # @intent: {"entity": "GET /repositories/new", "action": "name unread account beside panel", "behavior": "with one installation 404ing and another offering only unadministered repositories the page keeps the nothing-is-yours panel and adds GitHub no longer lists globex as connected", "layer": "request"}
    it "names an unread account beside the nothing-is-yours panel" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { not_found: true } : { repos: [github_repo("acme/api", admin: false)] }))
      end

      get new_repository_path

      expect(response.body).to include("Nothing here is yours to register")
      expect(response.body).to include("GitHub no longer lists globex as connected to SpecGuard")
      expect(response.body).not_to include("Anything shown here can still be registered")
    end

    # Which failures can reach an empty page at all — asserted rather than assumed, because it is
    # what makes the branch above tractable. `github_listing` is nil exactly when `registrable` is
    # empty AND `error` is set, so an empty page that RENDERS is one where `error` is nil, and the
    # only unread outcome that leaves `error` nil is the 404. A transiently-failing installation
    # with nothing else to show therefore does NOT land in the empty state: it lands on the panel
    # that names the refusal, which already explains it in its own words.
    #
    # So the 404 is not merely the likeliest thing the empty branches have to name — over the empty
    # page it is the ONLY one, which is precisely why the reading keyed on `error` could never see
    # it and the page fell silent.
    # @intent: {"entity": "GET /repositories/new", "action": "route transient failure", "behavior": "a transiently failing installation with nothing else to show lands on the GitHub-is-not-answering panel, never the empty state or an unread-account notice", "layer": "request"}
    it "sends a transiently-failing empty listing to the refusal panel rather than the empty state" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [] }))
      end

      get new_repository_path

      expect(response.body).to include("GitHub is not answering right now")
      expect(response.body).not_to include("No repositories connected yet")
      expect(response.body).not_to include("An account could not be read")
    end

    # The negative that keeps the fix from being "always warn". A viewer who genuinely selected
    # nothing has every installation ANSWERING, so there is no account to name and the original
    # sentence is the true one — it must still be what they are told.
    # @intent: {"entity": "GET /repositories/new", "action": "still blame selection", "behavior": "when the empty installation answered, the page keeps the No repositories connected yet and no-repositories-selected sentences with none of the unread-account wordings", "layer": "request"}
    it "still blames the selection when the empty installation answered" do
      stub_github(repos: [])

      get new_repository_path

      expect(response.body).to include("No repositories connected yet")
      expect(response.body).to include("no repositories are selected for it")
      expect(response.body).not_to include("An account could not be read")
      expect(response.body).not_to include("GitHub no longer lists")
      expect(response.body).not_to include("SpecGuard could not read")
    end

    # And the other guard the method kept: when there is no listing AT ALL the page has its own
    # dedicated panel naming GitHub's refusal, and that is not a short-list case — there is no page
    # for an account to be missing from. `github_unread_accounts` must stay empty there, or the
    # refusal panel grows a second, differently-worded explanation of the same request.
    # @intent: {"entity": "GET /repositories/new", "action": "leave refusal panel alone", "behavior": "with no listing at all the refusal panel explains GitHub is not answering right now without growing an An-account-could-not-be-read or SpecGuard-could-not-read clause", "layer": "request"}
    it "leaves the no-listing panel alone, which explains the refusal in its own words" do
      stub_github(unavailable: true)

      get new_repository_path

      expect(response.body).to include("GitHub is not answering right now")
      expect(response.body).not_to include("An account could not be read")
      expect(response.body).not_to include("SpecGuard could not read")
    end

    # A user with two installations, one of which will not answer. What WAS read is GitHub's own
    # answer and is still registerable, so the picker renders — but the page says the list is short
    # rather than letting "my repository is not here" read as "SpecGuard is broken".
    # @intent: {"entity": "GET /repositories/new", "action": "name unread installation in picker", "behavior": "with one installation unavailable the picker still renders acme/api in a select, warns This list may be incomplete, and names SpecGuard could not read globex just now rather than an anonymous one-of-your-installations phrase", "layer": "request"}
    it "renders the picker and names the installation that could not be read" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [github_repo("acme/api")] }))
      end

      get new_repository_path

      expect(response.body).to include("<select")
      expect(response.body).to include("acme/api")
      expect(response.body).to include("This list may be incomplete")
      # WHICH account. A user with `acme` and `globex` connected cannot act on "one of your GitHub
      # App installations" — they cannot tell whether the one that failed is the organization they
      # came to register, which is the whole question they are asking the page.
      expect(response.body).to include("SpecGuard could not read globex just now.")
      expect(response.body).not_to include("One of your GitHub App installations")
    end

    # The account this user connected with no login recorded — a callback can arrive without one —
    # must still be nameable, or the sentence above degrades to a blank where the name goes, which
    # is worse than the anonymous wording it replaced.
    # @intent: {"entity": "GET /repositories/new", "action": "use fallback installation name", "behavior": "an installation recorded with no login is named by the fallback sentence SpecGuard could not read Installation 6002 just now", "layer": "request"}
    it "names an installation with no recorded login by its fallback name" do
      add_github_installation(@user, installation_id: 6002)
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [github_repo("acme/api")] }))
      end

      get new_repository_path

      expect(response.body).to include("SpecGuard could not read Installation 6002 just now.")
    end

    # An installation GitHub answers 404 for is the case that rendered NOTHING before: a 404 is a
    # complete answer about an installation nobody can read any more, so it contributes an empty
    # listing and records no error — and the notice keyed on the error alone, so an entire account's
    # repositories could leave the picker in silence. An uninstall is the ordinary way a row goes
    # stale, which makes this the likeliest of the three, not the exotic one.
    # @intent: {"entity": "GET /repositories/new", "action": "name unlisted installation", "behavior": "a 404ing installation beside a working one still renders the acme/api picker with the incomplete-list warning and the sentence GitHub no longer lists globex as connected to SpecGuard", "layer": "request"}
    it "names an installation GitHub no longer lists, which said nothing at all before" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { not_found: true } : { repos: [github_repo("acme/api")] }))
      end

      get new_repository_path

      expect(response.body).to include("<select")
      expect(response.body).to include("acme/api")
      expect(response.body).to include("This list may be incomplete")
      expect(response.body).to include("GitHub no longer lists globex as connected to SpecGuard")
    end

    # Naming the account is free, and this is what says so: the outcomes are recorded during the
    # read the page already made, from installation rows already loaded to make it. Asserted as one
    # call PER INSTALLATION rather than as a zero — a re-read to find the name would show up here as
    # a second call, and a bare "no calls" assertion on a page that must call GitHub twice could
    # only pass by measuring nothing.
    # @intent: {"entity": "GET /repositories/new", "action": "name without re-reading", "behavior": "the globex unread sentence renders with exactly one repositories call against each of the two installations — no re-read to find the account name", "layer": "request"}
    it "names the failing account without asking GitHub again" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      fakes = { 5001 => FakeGithubApi.new(repos: [github_repo("acme/api")]),
                6002 => FakeGithubApi.new(unavailable: true) }
      stub_github_per_installation { |id| fakes.fetch(id) }

      get new_repository_path

      expect(response.body).to include("SpecGuard could not read globex just now.")
      expect(fakes[5001].calls_to(:repositories)).to eq(1)
      expect(fakes[6002].calls_to(:repositories)).to eq(1)
    end

    # The same short-list shape as above, with the unreadable installation returning a 401 rather
    # than an outage — and it must still render the picker. `collect` keeps the FIRST error and goes
    # on merging the installations that answered, so this viewer has `error == :not_authorized` AND
    # a repository they can register right now. Offering them the reconnect button instead would
    # take away a working picker to fix something that is not in their way; the honest answer is the
    # list, plus the note that it is short.
    # @intent: {"entity": "GET /repositories/new", "action": "prefer picker over reconnect", "behavior": "when only one installation rejects the token the picker still renders acme/api with the incomplete warning and the globex note, and no Reconnect to GitHub button", "layer": "request"}
    it "renders the picker rather than the reconnect button when only one installation rejects the token" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unauthorized: true } : { repos: [github_repo("acme/api")] }))
      end

      get new_repository_path

      expect(response.body).to include("<select")
      expect(response.body).to include("acme/api")
      expect(response.body).to include("This list may be incomplete")
      expect(response.body).to include("SpecGuard could not read globex just now.")
      expect(response.body).not_to include("Reconnect to GitHub")
    end

    # @intent: {"entity": "GET /repositories/new", "action": "stay silent when complete", "behavior": "a listing every installation answered renders no This-list-may-be-incomplete sentence", "layer": "request"}
    it "does not claim the list is incomplete when every installation answered" do
      stub_github(repos: [github_repo("acme/api")])

      get new_repository_path

      expect(response.body).not_to include("This list may be incomplete")
    end

    # And names nobody. The notice is the only thing that names an account, so a page without one
    # must not mention any — a reader whose installations all answered has nothing to act on.
    # @intent: {"entity": "GET /repositories/new", "action": "name nobody when healthy", "behavior": "a two-installation page whose listings both answered carries none of the three account-naming sentences", "layer": "request"}
    it "names no account when every installation answered" do
      add_github_installation(@user, installation_id: 6002, account_login: "globex")
      stub_github(repos: [github_repo("acme/api")])

      get new_repository_path

      expect(response.body).not_to include("This list may be incomplete")
      expect(response.body).not_to include("SpecGuard could not read")
      expect(response.body).not_to include("GitHub no longer lists")
    end

    # The only credential on this read is the viewer's own session token — `GithubApi` sends
    # `Authorization: Bearer <the user's token>` and nothing else, and there is no App id and no
    # private key in this codebase for GitHub to have rejected instead. So a 401 here is always the
    # user's own token, expired or revoked mid-session.
    #
    # That is precisely the case the reconnect button exists for, and it is the one the session
    # cannot see for itself: the token is locally unexpired and looks live until GitHub is asked.
    # Reporting it as an outage would tell the reader to wait out something that is not happening,
    # for as long as the stored expiry has left to run, when the fix is one click.
    # @intent: {"entity": "GET /repositories/new", "action": "offer reconnect on rejected token", "behavior": "a 401 against the user's own token renders the Reconnect to GitHub button linking the authorize path, with no outage wording and no select", "layer": "request"}
    it "offers the reconnect button when GitHub rejects the user's token" do
      # Configured so the real button renders rather than the operator notice that stands in for it
      # — the assertion below is about the button being OFFERED, not about the panel's heading.
      allow(SpecGuard::GithubApp).to receive_messages(configured?: true, slug: "specguard")
      stub_github(unauthorized: true)

      get new_repository_path

      expect(response.body).to include("Reconnect to GitHub")
      expect(response.body).to include(github_installation_authorize_path)
      expect(response.body).not_to include("GitHub is not answering right now")
      expect(response.body).not_to include("<select")
    end

    # The other half of the pair above, and the reason the two must not collapse into one answer.
    # An outage is waitable and offers no button; a rejected token is not waitable and offers
    # nothing else. Reading either as the other tells the user to do the one thing that cannot work.
    # @intent: {"entity": "GET /repositories/new", "action": "report outage honestly", "behavior": "an unavailable GitHub renders the GitHub-is-not-answering-right-now panel with no reconnect button and no select", "layer": "request"}
    it "says so, rather than showing an empty picker, when GitHub will not answer" do
      stub_github(unavailable: true)

      get new_repository_path

      expect(response.body).to include("GitHub is not answering right now")
      expect(response.body).not_to include("Reconnect to GitHub")
      expect(response.body).not_to include("<select")
    end

    # The listing call hits GitHub with the same credential and collects the same 403s as
    # verification does, so it must make the same distinction. A rate limit clears by waiting and
    # says so; reporting it as an outage would be true-ish and useless.
    # @intent: {"entity": "GET /repositories/new", "action": "name listing rate limit", "behavior": "a rate-limited listing renders GitHub refused the request with the words rate limit, and never the is-not-answering outage wording", "layer": "request"}
    it "names the rate limit rather than reporting it as an outage when listing" do
      stub_github(forbidden: :rate_limited)

      get new_repository_path

      expect(response.body).to include("GitHub refused the request")
      expect(response.body).to include("rate limit")
      expect(response.body).not_to include("GitHub is not answering right now")
    end
  end

  # The rename form's own case. The picker offers what the installation covers *now*, but the
  # record being renamed already has a name — and the whole reason to open this form is that the
  # name is stale. A repository registered before verification existed, renamed on GitHub since, or
  # sitting past the listing cap is absent from that list, and the control that is supposed to show
  # its current value would show someone else's instead.
  describe "GET /repositories/:id/edit" do
    # @intent: {"entity": "GET /repositories/:id/edit", "action": "offer current name", "behavior": "the rename form answers 200 and renders the persisted acme/legacy-tracker as a select option beside the listing's acme/billing-service", "layer": "request"}
    it "offers the current name even when GitHub's listing does not contain it" do
      repository = create_repository(user: @user, github_full_name: "acme/legacy-tracker")
      stub_github(repos: [github_repo("acme/billing-service")])

      get edit_repository_path(repository)

      expect(response).to have_http_status(:ok)
      # The option, not merely the string: the page's title and breadcrumb both render the
      # persisted name from `github_full_name_was` regardless, so a bare text match would stay
      # green with the picker's concession removed.
      expect(response.body).to include('value="acme/legacy-tracker"')
      expect(response.body).to include('value="acme/billing-service"')
    end

    # @intent: {"entity": "GET /repositories/:id/edit", "action": "select current name", "behavior": "the prepended legacy option carries the selected attribute, so the control opens showing the value it describes", "layer": "request"}
    it "selects that prepended name, so the control opens showing the value it describes" do
      repository = create_repository(user: @user, github_full_name: "acme/legacy-tracker")
      stub_github(repos: [github_repo("acme/billing-service")])

      get edit_repository_path(repository)

      expect(response.body).to match(/<option selected[^>]*value="acme\/legacy-tracker"/)
    end

    # The guard above the concession. When the current name *is* in the listing — the ordinary
    # case, and the one every other spec that renders this form is in — prepending it again would
    # offer the same repository twice.
    # @intent: {"entity": "GET /repositories/:id/edit", "action": "avoid duplicate option", "behavior": "when the listing already contains the current name the value acme/billing-service appears exactly once among the rendered options", "layer": "request"}
    it "does not offer the current name twice when GitHub's listing already contains it" do
      repository = create_repository(user: @user, github_full_name: "acme/billing-service")
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/checkout")])

      get edit_repository_path(repository)

      expect(response.body.scan('value="acme/billing-service"').length).to eq(1)
    end

    # Why the concession reads `github_full_name_was` and not `github_full_name`. On a 422
    # re-render the rejected input is already assigned onto the record, so the plain attribute is
    # the name GitHub just refused. Prepending *that* would offer the user the very value the
    # server would reject again, and would drop the real one they are trying to rename away from.
    # @intent: {"entity": "GET /repositories/:id/edit", "action": "prepend persisted name", "behavior": "after a refused rename the re-rendered form offers value acme/legacy-tracker and never the rejected ghost/repo input", "layer": "request"}
    it "prepends the persisted name, not the rejected input, when a rename comes back refused" do
      repository = create_repository(user: @user, github_full_name: "acme/legacy-tracker")
      stub_github(repos: [github_repo("acme/billing-service")])

      patch repository_path(repository), params: { repository: { github_full_name: "ghost/repo" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('value="acme/legacy-tracker"')
      expect(response.body).not_to include('value="ghost/repo"')
    end
  end

  # The scenario the audit named, at the level it actually bites.
  #
  # GitHub hands an organization's installation to EVERY member of that organization — `GET
  # /user/installations` grants it at `:read`, which plain membership gives — so two users
  # legitimately hold a row for the same installation id. Reading that installation with a
  # credential that speaks for the APP answers both of them identically, which is how a read-only
  # member came to be offered fifty repositories they cannot even see on github.com. Reading it with
  # a credential that speaks for the PERSON cannot: GitHub answers each of them about their own
  # access.
  #
  # So this is one installation, one repository, two sessions, and two different answers.
  describe "two users holding the same installation" do
    # @intent: {"entity": "Repository", "action": "answer per user", "behavior": "holding one installation id, the owner's token is offered acme/vault on the picker while the member's is not, and the member posting acme/vault creates no row and draws the 422 does-not-list-you-as-an-administrator answer", "layer": "request"}
    it "answers each of them with their own access, not the App's" do
      # The fake keys off the credential, which is the whole claim: the same installation id, read
      # with two different tokens, comes back differently.
      GithubApi.factory = lambda { |token, installation_id|
        raise "expected the shared installation, got #{installation_id}" unless installation_id == 4242

        FakeGithubApi.new(repos: [github_repo("acme/vault", admin: token == "ghu_owner")])
      }

      sign_in_via_github(uid: "3003", info: { nickname: "owner" }, installation: false)
      authorize_github_app(installations: [[4242, "acme"]], token: "ghu_owner")

      get new_repository_path
      expect(response.body).to include("acme/vault")

      delete sign_out_path

      sign_in_via_github(uid: "4004", info: { nickname: "member" }, installation: false)
      authorize_github_app(installations: [[4242, "acme"]], token: "ghu_member")

      # Not offered...
      get new_repository_path
      expect(response.body).not_to include("acme/vault")

      # ...and not registerable by naming it at the endpoint either, which is the move that matters.
      expect { register("acme/vault") }.not_to change(Repository, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("does not list you as an administrator")
    end
  end
end
