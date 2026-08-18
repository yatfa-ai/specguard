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
    it "refuses a repository in the installation that this user does not administer" do
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/vault", admin: false)])

      expect { register("acme/vault") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("does not list you as an administrator")
    end

    # And it is not merely refused at the write — it is never offered. The picker and the gate are
    # built from the same object, so a page cannot show something the POST would turn down.
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
    it "refuses a repository GitHub has never heard of, in the same words" do
      stub_github(repos: [])

      expect { register("ghost/repo") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not one of the repositories the SpecGuard GitHub App is installed on")
    end

    # Fails closed. If an outage were treated as a pass, the gap would reopen on every GitHub 500 —
    # which is a worse property than the one being fixed, because it is intermittent.
    it "refuses to register anything while GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("could not read your full repository list")
    end

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
    it "reports a refusal without telling the user to wait it out" do
      stub_github(forbidden: :refused)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("could not read your full repository list")
    end

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
    it "checks the normalized name against the installation, not the pasted one" do
      stub_github(repos: [github_repo("acme/billing-service")])

      register("https://github.com/acme/billing-service")

      expect(response).to redirect_to(repository_path(Repository.last))
      expect(Repository.last.github_full_name).to eq("acme/billing-service")
    end

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

    it "refuses to rename onto a repository outside the installation" do
      stub_github(repos: [github_repo("acme/billing-service")])

      rename("someone-else/private-repo")

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    it "refuses to rename onto a repository GitHub cannot see" do
      stub_github(repos: [])

      rename("ghost/repo")

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    it "renames onto another repository in the installation" do
      stub_github(repos: [github_repo("acme/checkout")])

      rename("acme/checkout")

      expect(response).to redirect_to(repository_path(repository))
      expect(repository.reload.github_full_name).to eq("acme/checkout")
    end

    # An unchanged submit changes no identity, so there is nothing to verify — and, just as
    # importantly, it must not start failing during a GitHub outage for a write that does nothing.
    it "does not ask GitHub when the submitted name is unchanged" do
      fake = stub_github(unavailable: true)

      rename("acme/billing-service")

      expect(response).to redirect_to(repository_path(repository))
      expect(fake.calls_to(:repositories)).to eq(0)
    end

    # The create path's twin: here `request.fullpath` is `/repositories/:id`, the PATCH path, which
    # renders the show page rather than the rename form.
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
    it "refuses to rename anything while GitHub cannot be reached" do
      stub_github(unavailable: true)

      rename("acme/checkout")

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
      expect(response.body).to include("could not read your full repository list")
    end
  end

  describe "GET /repositories/new" do
    it "offers the installation's repositories as a list rather than a free-text field" do
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/checkout")])

      get new_repository_path

      expect(response.body).to include("<select")
      expect(response.body).to include("acme/billing-service")
      expect(response.body).to include("acme/checkout")
      # The field that made squatting a matter of typing.
      expect(response.body).not_to include('placeholder="org/repo"')
    end

    # Nothing is withheld, and the picker says where the list comes from instead of apologising for
    # its length. The old page had to explain why most of what GitHub returned was not on offer —
    # `/user/repos` listed every repository the user had any relationship with. An installation
    # contains only what somebody deliberately selected, so the offered set and the registerable set
    # are the same set.
    it "offers everything in the installation, and says where the list comes from" do
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/checkout")])

      get new_repository_path

      expect(response.body).to include("acme/billing-service")
      expect(response.body).to include("acme/checkout")
      expect(response.body).to include("These are the repositories the SpecGuard GitHub App is installed on")
      expect(response.body).not_to include("you do not administer")
    end

    it "marks a private repository as private in the list" do
      stub_github(repos: [github_repo("acme/secrets", private: true)])

      get new_repository_path

      expect(response.body).to include("acme/secrets · private")
    end

    # The other half of the note. `archived` changes what registering means as much as `private`
    # does — an archived repository will never push another CI run — so it has to be readable on
    # the option rather than discoverable after registering.
    it "marks an archived repository as archived in the list" do
      stub_github(repos: [github_repo("acme/legacy-tracker", archived: true)])

      get new_repository_path

      expect(response.body).to include("acme/legacy-tracker · archived")
    end

    # Both notes at once, asserted with the join intact: the label is one `·` and then a
    # comma-joined list, not two separate `·` groups, and the order is private-then-archived.
    it "marks a repository that is both private and archived with both notes" do
      stub_github(repos: [github_repo("acme/vault", private: true, archived: true)])

      get new_repository_path

      expect(response.body).to include("acme/vault · private, archived")
    end

    # The third sentence of the hint, which only appears when GitHub's listing hit the page walk's
    # ceiling. The figure is re-derived from the two constants that produce it rather than written
    # as `1000`: a literal here would keep reading green after a change to either constant while
    # the page told the user a capacity the client no longer has.
    it "says the listing was capped, at the capacity the client actually walks" do
      stub_github(truncated: true)

      get new_repository_path

      expect(response.body).to include(
        "Showing the first #{GithubApi::MAX_PAGES * GithubApi::PER_PAGE} repositories GitHub returned."
      )
    end

    it "does not claim the listing was capped when it was not" do
      stub_github

      get new_repository_path

      expect(response.body).not_to include("Showing the first")
    end

    it "asks for the installation instead of a picker when nothing is connected yet" do
      uninstall_github_app(@user)

      get new_repository_path

      expect(response.body).to include("Connect your GitHub repositories")
      expect(response.body).to include("SpecGuard connects repositories through a GitHub App")
      expect(response.body).not_to include("<select")
    end

    # Installed, and covering nothing — the user completed the flow and selected no repositories, or
    # has since deselected them all. Distinct from "not installed": installing again would do
    # nothing, and the fix is choosing repositories on GitHub.
    it "distinguishes an installation that covers nothing from no installation at all" do
      stub_github(repos: [])

      get new_repository_path

      expect(response.body).to include("No repositories connected yet")
      expect(response.body).not_to include("<select")
    end

    # A user with two installations, one of which will not answer. What WAS read is GitHub's own
    # answer and is still registerable, so the picker renders — but the page says the list is short
    # rather than letting "my repository is not here" read as "SpecGuard is broken".
    it "renders the picker and says so when one installation could not be read" do
      add_github_installation(@user, installation_id: 6002)
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [github_repo("acme/api")] }))
      end

      get new_repository_path

      expect(response.body).to include("<select")
      expect(response.body).to include("acme/api")
      expect(response.body).to include("This list may be incomplete")
    end

    it "does not claim the list is incomplete when every installation answered" do
      stub_github(repos: [github_repo("acme/api")])

      get new_repository_path

      expect(response.body).not_to include("This list may be incomplete")
    end

    # An operator-side failure — a wrong App id, a private key that is not this App's — is nothing
    # the user can act on, so it is reported as GitHub not answering rather than as a button that
    # cannot help. The reason goes to the log.
    it "reports rejected App credentials as an outage rather than as the user's problem" do
      stub_github(unauthorized: true)

      get new_repository_path

      expect(response.body).to include("GitHub is not answering right now")
      expect(response.body).not_to include("<select")
    end

    it "says so, rather than showing an empty picker, when GitHub will not answer" do
      stub_github(unavailable: true)

      get new_repository_path

      expect(response.body).to include("GitHub is not answering right now")
      expect(response.body).not_to include("<select")
    end

    # The listing call hits GitHub with the same credential and collects the same 403s as
    # verification does, so it must make the same distinction. A rate limit clears by waiting and
    # says so; reporting it as an outage would be true-ish and useless.
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

    it "selects that prepended name, so the control opens showing the value it describes" do
      repository = create_repository(user: @user, github_full_name: "acme/legacy-tracker")
      stub_github(repos: [github_repo("acme/billing-service")])

      get edit_repository_path(repository)

      expect(response.body).to match(/<option selected[^>]*value="acme\/legacy-tracker"/)
    end

    # The guard above the concession. When the current name *is* in the listing — the ordinary
    # case, and the one every other spec that renders this form is in — prepending it again would
    # offer the same repository twice.
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
