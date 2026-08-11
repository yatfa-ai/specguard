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
RSpec.describe "Ownership-verified repository registration", type: :request do
  before { @user = sign_in_via_github }

  def register(full_name)
    post repositories_path, params: { repository: { github_full_name: full_name } }
  end

  describe "POST /repositories" do
    it "registers a repository GitHub says the user administers" do
      stub_github(repos: [github_repo("acme/billing-service", admin: true)], strict: true)

      expect { register("acme/billing-service") }.to change(Repository, :count).by(1)

      expect(response).to redirect_to(repository_path(Repository.last))
      expect(Repository.last.user).to eq(@user)
    end

    # THE example. The repository exists, the user can see it, and it is not theirs.
    it "refuses a repository the user does not administer" do
      stub_github(repos: [github_repo("someone-else/private-repo", admin: false)], strict: true)

      expect { register("someone-else/private-repo") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not a repository you administer on GitHub")
    end

    it "refuses a repository GitHub has never heard of" do
      stub_github(repos: [], strict: true)

      expect { register("ghost/repo") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("was not found on GitHub")
    end

    # Fails closed. If an outage were treated as a pass, the gap would reopen on every GitHub 500 —
    # which is a worse property than the one being fixed, because it is intermittent.
    it "refuses to register anything while GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("GitHub did not answer")
    end

    it "refuses when the user has not authorized repository access, and offers the grant" do
      revoke_github_repository_access(@user)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Connect your GitHub repositories")
    end

    # The authorize button on a 422 has to come back to the form, and the form is a GET the user is
    # no longer on: `request.fullpath` here is `/repositories`, the POST path, which renders the
    # index. A user who submits, is told to connect GitHub, and grants it would land on the
    # dashboard and have to find "Register" again — on the one path they are most likely to press
    # the button.
    it "returns the user to the registration form after authorizing from a failed registration" do
      revoke_github_repository_access(@user)

      register("acme/billing-service")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML("origin=#{CGI.escape(new_repository_path)}"))
      expect(response.body).not_to include(CGI.escapeHTML("origin=#{CGI.escape(repositories_path)}&"))
    end

    # An SSO-enforced organization answers 403 forever until a human authorizes the token for it.
    # "GitHub did not answer. Try again shortly." is the one sentence that guarantees the user
    # retries in a loop, so this asserts both the right words and the absence of the wrong ones.
    it "tells an SSO-blocked user what actually resolves it, not to wait" do
      stub_github(forbidden: :sso_required)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("organization may need to approve SpecGuard")
      expect(response.body).not_to include("GitHub did not answer")
    end

    it "names the rate limit rather than reporting it as an outage" do
      stub_github(forbidden: :rate_limited)

      expect { register("acme/billing-service") }.not_to change(Repository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("rate limit")
      expect(response.body).not_to include("GitHub did not answer")
    end

    # Shape and uniqueness are the record's own rules and cost nothing to check. Asking GitHub
    # about a string that could not be a repository name is a round trip whose answer is already
    # known, on a path a signed-in user can hammer. (The 422 re-render then lists the picker, which
    # is a different question and a different endpoint — hence `calls_to(:repository)`.)
    it "does not ask GitHub about a name that is not org/repo" do
      fake = stub_github

      register("nonsense")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must look like org/repo")
      expect(fake.calls_to(:repository)).to eq(0)
    end

    it "asks GitHub about the normalized name, not the pasted one" do
      fake = stub_github(repos: [github_repo("acme/billing-service")], strict: true)

      register("https://github.com/acme/billing-service")

      expect(response).to redirect_to(repository_path(Repository.last))
      expect(fake.calls).to eq([[:repository, "acme/billing-service"]])
    end
  end

  # The sibling writer. `#update` is owner-only, but owning the SpecGuard *record* is exactly what
  # a squatter has — so "owner-only" was never an ownership check.
  describe "PATCH /repositories/:id" do
    let(:repository) { create_repository(user: @user, github_full_name: "acme/billing-service") }

    def rename(full_name)
      patch repository_path(repository), params: { repository: { github_full_name: full_name } }
    end

    it "refuses to rename onto a repository the user does not administer" do
      stub_github(repos: [github_repo("someone-else/private-repo", admin: false)], strict: true)

      rename("someone-else/private-repo")

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    it "refuses to rename onto a repository GitHub cannot see" do
      stub_github(repos: [], strict: true)

      rename("ghost/repo")

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    it "renames onto another repository the user administers" do
      stub_github(repos: [github_repo("acme/checkout")], strict: true)

      rename("acme/checkout")

      expect(response).to redirect_to(repository_path(repository))
      expect(repository.reload.github_full_name).to eq("acme/checkout")
    end

    # An unchanged submit changes no identity, so there is nothing to verify — and, just as
    # importantly, it must not start failing during a GitHub outage for a write that does nothing.
    it "does not ask GitHub when the submitted name is unchanged" do
      fake = stub_github

      rename("acme/billing-service")

      expect(response).to redirect_to(repository_path(repository))
      expect(fake.calls_to(:repository)).to eq(0)
    end

    # The create path's twin: here `request.fullpath` is `/repositories/:id`, the PATCH path, which
    # renders the show page rather than the rename form.
    it "returns the user to the rename form after authorizing from a failed rename" do
      revoke_github_repository_access(@user)

      rename("acme/checkout")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body)
        .to include(CGI.escapeHTML("origin=#{CGI.escape(edit_repository_path(repository))}"))
    end

    it "tells an SSO-blocked user what actually resolves it, not to wait" do
      stub_github(forbidden: :sso_required)

      rename("acme/checkout")

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
      expect(response.body).to include("organization may need to approve SpecGuard")
      expect(response.body).not_to include("GitHub did not answer")
    end
  end

  describe "GET /repositories/new" do
    it "offers the user's administered repositories as a list rather than a free-text field" do
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/checkout")])

      get new_repository_path

      expect(response.body).to include("<select")
      expect(response.body).to include("acme/billing-service")
      expect(response.body).to include("acme/checkout")
      # The field that made squatting a matter of typing.
      expect(response.body).not_to include('placeholder="org/repo"')
    end

    # Offering a repository the server will refuse is offering a click that can only end in a 422.
    it "withholds repositories the user cannot administer, and says how many" do
      stub_github(repos: [github_repo("acme/billing-service"),
                          github_repo("rails/rails", admin: false)])

      get new_repository_path

      expect(response.body).to include("acme/billing-service")
      expect(response.body).not_to include("rails/rails")
      expect(response.body).to include("1 repository you do not administer is not listed")
    end

    it "marks a private repository as private in the list" do
      stub_github(repos: [github_repo("acme/secrets", private: true)])

      get new_repository_path

      expect(response.body).to include("acme/secrets · private")
    end

    it "asks for authorization instead of a picker when GitHub is not connected yet" do
      revoke_github_repository_access(@user)

      get new_repository_path

      expect(response.body).to include("Connect your GitHub repositories")
      expect(response.body).to include("SpecGuard will ask GitHub for access to your repositories")
      expect(response.body).not_to include("<select")
    end

    it "asks for authorization again when GitHub rejects the stored token" do
      stub_github(unauthorized: true)

      get new_repository_path

      expect(response.body).to include("Connect your GitHub repositories")
    end

    it "says so, rather than showing an empty picker, when GitHub will not answer" do
      stub_github(unavailable: true)

      get new_repository_path

      expect(response.body).to include("GitHub is not answering right now")
      expect(response.body).not_to include("<select")
    end

    # The listing call hits GitHub with the same token and collects the same 403s as verification
    # does, so it must make the same distinction. "GitHub is not answering right now" is false here
    # — GitHub answered, and said no.
    it "distinguishes GitHub refusing from GitHub being down when listing" do
      stub_github(forbidden: :sso_required)

      get new_repository_path

      expect(response.body).to include("GitHub refused the request")
      expect(response.body).to include("organization may need to approve SpecGuard")
      expect(response.body).not_to include("GitHub is not answering right now")
    end

    # A too-narrow grant is the one 403 a re-authorization fixes, so it gets the button rather than
    # an explanation the user cannot act on.
    it "offers the grant when the token is too narrow to list repositories" do
      stub_github(forbidden: :insufficient_scope)

      get new_repository_path

      expect(response.body).to include("Connect your GitHub repositories")
      expect(response.body).not_to include("<select")
    end
  end
end
