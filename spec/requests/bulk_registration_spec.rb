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
RSpec.describe "Bulk organization registration", type: :request do
  before { @user = sign_in_via_github }

  def choose_organization(login) = get bulk_repositories_path(organization: login)

  def submit(names, organization: "acme")
    post bulk_repositories_path, params: { organization: organization, github_full_names: names }
  end

  describe "GET /repositories/bulk — choosing an organization" do
    it "lists the organizations the user administers something in, with counts" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"),
                          github_repo("beta/thing")])

      get bulk_repositories_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme")
      expect(response.body).to include("beta")
      expect(response.body).to include("2 repositories")
    end

    it "does not offer an organization the user administers nothing in" do
      stub_github(repos: [github_repo("acme/api"), github_repo("readonly/thing", admin: false)])

      get bulk_repositories_path

      expect(response.body).to include("acme")
      expect(response.body).not_to include("readonly")
    end

    # A personal namespace is not an organization, and this page says "organization".
    it "does not offer the user's own repositories as an organization" do
      stub_github(repos: [github_repo("acme/api"),
                          github_repo("octocat/dotfiles", owner_type: "User")])

      get bulk_repositories_path

      expect(response.body).not_to include("octocat/dotfiles")
    end

    it "says so plainly when there is no organization to register from" do
      stub_github(repos: [github_repo("octocat/dotfiles", owner_type: "User")])

      get bulk_repositories_path

      expect(response.body).to include("No organizations to register from")
    end

    # The listing cap is GLOBAL, so truncation can hide a whole organization rather than some of
    # one organization's repositories — a different and worse failure than a short list.
    it "says the organization list may be incomplete when GitHub's listing was truncated" do
      stub_github(repos: [github_repo("acme/api")], truncated: true)

      get bulk_repositories_path

      expect(response.body).to include("missing an organization")
    end
  end

  describe "GET /repositories/bulk?organization= — choosing repositories" do
    it "lists the organization's repositories the user administers" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web"),
                          github_repo("beta/elsewhere")])

      choose_organization("acme")

      expect(response.body).to include("acme/api")
      expect(response.body).to include("acme/web")
      expect(response.body).not_to include("beta/elsewhere")
    end

    it "withholds repositories the user does not administer, and counts them" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/legacy", admin: false)])

      choose_organization("acme")

      expect(response.body).not_to include("acme/legacy")
      expect(response.body).to include("1 repository you do not administer")
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

    # A stale bookmark, a renamed organization and a typed query string are ordinary ways to arrive
    # here. None of them is an error page.
    it "falls back to the chooser for an organization the user cannot register from" do
      stub_github(repos: [github_repo("acme/api")])

      choose_organization("strangers")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Organizations GitHub reports you administer")
    end
  end

  describe "POST /repositories/bulk — registering" do
    it "registers the selected repositories and reports what it did" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")], strict: true)

      expect { submit(%w[acme/api acme/web]) }.to change(Repository, :count).by(2)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Registered 2 repositories.")
      expect(@user.repositories.pluck(:github_full_name)).to match_array(%w[acme/api acme/web])
    end

    # The honest summary the ticket asks for: two numbers that add up to the submission, with the
    # skips broken down by reason rather than collapsed into a single failure.
    it "reports registered and skipped separately, with the reason for each skip" do
      create_repository(user: @user, github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/theirs", admin: false),
                          github_repo("acme/taken")], strict: true)

      submit(%w[acme/api acme/theirs acme/taken])

      expect(response.body).to include("Registered 1 repository.")
      expect(response.body).to include("Skipped 2.")
      expect(response.body).to include("Already registered (1)")
      expect(response.body).to include("Not administered by you on GitHub (1)")
      expect(response.body).to include("is not a repository you administer on GitHub")
    end

    # THE example for this slice. The form is not the gate: a POST naming a repository the page
    # never offered is refused by asking GitHub, exactly as a single registration is.
    it "refuses a repository the user does not administer even when the form never offered it" do
      stub_github(repos: [github_repo("acme/api"), github_repo("someone-else/theirs", admin: false)],
                  strict: true)

      expect { submit(%w[someone-else/theirs]) }.not_to change(Repository, :count)

      expect(response.body).to include("Not administered by you on GitHub")
    end

    it "refuses a repository GitHub cannot see, submitted directly" do
      stub_github(repos: [github_repo("acme/api")], strict: true)

      expect { submit(%w[ghost/repo]) }.not_to change(Repository, :count)

      expect(response.body).to include("Not visible to your GitHub account")
    end

    # Fails closed: an outage that registered by default would reopen the squatting gap on every
    # GitHub 500.
    it "registers nothing while GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect { submit(%w[acme/api acme/web]) }.not_to change(Repository, :count)

      expect(response.body).to include("GitHub could not be reached")
    end

    it "offers the authorize button when the batch was refused for a missing grant" do
      revoke_github_repository_access(@user)

      expect { submit(%w[acme/api]) }.not_to change(Repository, :count)

      expect(response.body).to include("Connect your GitHub repositories")
      expect(response.body).to include(CGI.escapeHTML("origin=#{CGI.escape(bulk_repositories_path)}"))
    end

    it "links to each repository it registered" do
      stub_github(repos: [github_repo("acme/api")], strict: true)

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

    # The create path has already walked GitHub's listing inside `GithubOwnership.verify_batch`.
    # Re-deriving "is authorization needed?" from the listing afterwards costs a second full page
    # walk — up to `GithubApi::MAX_PAGES` round trips — to answer a question the verdict already
    # holds. `GithubRepositoryListing#github_authorization_needed?` reads the verdict first.
    it "asks GitHub for the listing exactly once across a registration" do
      fake = stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")], strict: true)

      submit(%w[acme/api acme/web])

      expect(response.body).to include("Registered 2 repositories.")
      expect(fake.calls_to(:repositories)).to eq(1)
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
      stub_github(repos: [github_repo("acme/api")], strict: true)

      expect { submit(names) }.to change(Repository, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Registered 1 repository.")
    end

    # De-duplication runs on the NORMALISED name, so the two spellings of one repository do not
    # survive as two candidates — which would register the first and then report the second as
    # already-registered against a row this very batch had just created.
    it "treats a URL and a bare slug for one repository as one repository" do
      stub_github(repos: [github_repo("acme/api")], strict: true)

      expect { submit(["acme/api", "https://github.com/acme/api", "acme/api.git"]) }
        .to change(Repository, :count).by(1)

      expect(response.body).to include("Registered 1 repository.")
      expect(response.body).not_to include("Already registered")
    end

    # `params` can be any shape a client cares to send. A Hash where an Array is expected, and
    # non-scalar entries, must not become a 500 or a repository named `{"a"=>"b"}`.
    it "survives a submission that is not the shape the form sends" do
      stub_github(repos: [github_repo("acme/api")], strict: true)

      post bulk_repositories_path, params: { github_full_names: { "0" => "acme/api", "1" => "" } }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Registered 1 repository.")
    end

    it "ignores non-scalar entries rather than naming them as repositories" do
      stub_github(repos: [github_repo("acme/api")], strict: true)

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
    end

    # Nothing is wrong with GitHub and waiting will not help, so this must not say "try again
    # shortly" — the same distinction the single-repository form makes.
    it "tells an SSO-blocked user what actually resolves it, not to wait" do
      stub_github(forbidden: :sso_required)

      get bulk_repositories_path

      expect(response.body).to include("GitHub refused the request")
      expect(response.body).not_to include("GitHub is not answering right now")
    end

    it "offers the grant when the user has never connected GitHub" do
      revoke_github_repository_access(@user)

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
