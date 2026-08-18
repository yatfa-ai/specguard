# frozen_string_literal: true

require "rails_helper"

# Connecting repositories, end to end through the controller.
#
# Signing in and connecting repositories are two different asks of the same person, and after
# SPGD-424 they are two different MECHANISMS: sign-in is OAuth and asks for identity alone, and
# connecting repositories is installing a GitHub App, whose membership is itself the proof that a
# repository is the user's to register. A visitor who only ever looks at a dashboard is never asked
# for anything about their repositories, and nothing in the app can read one without an
# installation.
RSpec.describe "GitHub App installation", type: :request do
  # Both halves of the flow need the App to look configured. Development, test and CI never have
  # real App credentials — that is the whole reason `configured?` exists — so a spec about the flow
  # says so rather than requiring a private key to exist.
  def with_configured_app
    allow(SpecGuard::GithubApp).to receive_messages(
      configured?: true, slug: "specguard", app_id: "123456",
      client_id: "Iv1.test", client_secret: "secret"
    )
  end

  # The one seam the callback rests on: GitHub's own answer to "which installations does this user
  # hold". Stubbed at the service rather than over HTTP, the same discipline `GithubApi.factory`
  # follows — no spec reaches github.com and none needs a real code to exchange.
  def stub_user_installations(*installations)
    allow(GithubAppUserAuthorization).to receive(:installations).and_return(
      installations.map do |attrs|
        GithubAppUserAuthorization::Installation.new(
          installation_id: attrs.fetch(:installation_id), account_login: attrs[:account_login]
        )
      end
    )
  end

  describe "what each entry point asks for" do
    # The whole point of keeping the two apart. If sign-in asked for `repo`, every visitor would be
    # handing over read and write access to their private repositories in order to look at a
    # dashboard.
    it "asks a visitor signing in for identity scopes only" do
      expect(SpecGuard::GithubOauth::SIGN_IN_SCOPE).to eq("read:user,user:email")
      expect(SpecGuard::GithubOauth::SIGN_IN_SCOPE).not_to include("repo")

      # The suite runs with placeholder OAuth credentials, and the home page withholds the button
      # rather than dead-ending a visitor when the provider is unconfigured — so the button has to
      # be asked for before it can be asserted on.
      allow(SpecGuard::GithubOauth).to receive(:configured?).and_return(true)

      get root_path

      expect(response.body).to include('action="/auth/github"')
      expect(response.body).not_to include("scope=")
    end

    # The constant that used to hold `repo` is gone, not merely unused. A grep is the assertion
    # because the failure mode being guarded against is somebody reintroducing it: the app has no
    # column to put a repository token in any more, so a scope here would buy access nothing reads
    # and everything would still appear to work.
    it "has no repository scope left to request" do
      expect(SpecGuard::GithubOauth.constants).not_to include(:REPOSITORY_SCOPE)
      expect(User.column_names).not_to include("github_access_token", "github_token_scopes")
    end

    # Registering is where the offer appears, and what it offers is an installation rather than a
    # broader grant.
    it "offers the installation flow at the point of registering a repository" do
      with_configured_app
      sign_in_via_github(installation: false)

      get new_repository_path

      expect(response.body).to include('action="/github/installation?return_to=%2Frepositories%2Fnew"')
      expect(response.body).to include("SpecGuard connects repositories through a GitHub App")
      expect(response.body).to include("read-only access to their metadata")
    end

    # An unconfigured instance says so BEFORE the click, rather than bouncing the reader to a
    # github.com URL built from placeholders — a 404 on somebody else's site with nothing here to
    # explain it.
    it "explains itself rather than offering a button an unconfigured instance cannot honour" do
      sign_in_via_github(installation: false)

      get new_repository_path

      expect(response.body).to include("The SpecGuard GitHub App is not configured")
      expect(response.body).to include("GITHUB_APP_ID")
      expect(response.body).not_to include('action="/github/installation')
    end
  end

  describe "POST /github/installation" do
    before { with_configured_app }

    it "sends the user to GitHub's own installation flow" do
      sign_in_via_github(installation: false)

      post github_installation_path, params: { return_to: "/repositories/new" }

      expect(response).to redirect_to(
        "https://github.com/apps/specguard/installations/new?state=%2Frepositories%2Fnew"
      )
    end

    # `state` is round-tripped through GitHub and comes back as user-controlled input, so a value
    # that leaves this site is discarded on the way OUT as well as on the way back. Discarded rather
    # than corrected: a value we cannot vouch for is not one to repair into something adjacent.
    it "refuses to carry a return path that leaves this site" do
      sign_in_via_github(installation: false)

      post github_installation_path, params: { return_to: "https://evil.example/phish" }

      expect(response).to redirect_to(
        "https://github.com/apps/specguard/installations/new?state=%2Frepositories"
      )
    end

    it "requires a signed-in user" do
      post github_installation_path

      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /github/installation/callback" do
    before { with_configured_app }

    it "records every installation GitHub reports for this user" do
      user = sign_in_via_github(installation: false)
      stub_user_installations({ installation_id: 777, account_login: "acme" },
                              { installation_id: 888, account_login: "beta" })

      expect { get github_installation_callback_path, params: { installation_id: 777, code: "abc" } }
        .to change { user.github_installations.count }.from(0).to(2)

      expect(user.github_installations.pluck(:installation_id)).to contain_exactly(777, 888)
      expect(flash[:notice]).to eq("Connected acme and beta.")
    end

    # THE SECURITY PROPERTY OF THIS ENDPOINT. `installation_id` is a query string on a GET: anyone
    # can type it, with anyone else's installation id in it. Recording it unchecked would hand the
    # forger every repository in a stranger's installation — the squatting gap this slice closes,
    # reopened at a wider gauge, since an installation is a SET of repositories rather than one.
    #
    # What settles it is the `code`, which GitHub issued to the browser that actually completed the
    # flow. So the id in the URL is never read: only what GitHub answers is recorded.
    it "records what GitHub reports, never the installation id in the URL" do
      user = sign_in_via_github(installation: false)
      stub_user_installations({ installation_id: 777, account_login: "acme" })

      get github_installation_callback_path, params: { installation_id: 999_999, code: "abc" }

      expect(user.github_installations.pluck(:installation_id)).to eq([777])
    end

    # A forged callback carries no usable code, so the exchange fails and nothing is recorded. The
    # user is exactly as connected as they were before, which is the only safe reading of "GitHub
    # would not confirm this".
    it "records nothing when GitHub will not confirm the authorization" do
      user = sign_in_via_github(installation: false)
      allow(GithubAppUserAuthorization).to receive(:installations)
        .and_raise(GithubApi::Unauthorized, "bad code")

      get github_installation_callback_path, params: { installation_id: 777 }

      expect(user.github_installations).to be_empty
      expect(flash[:alert]).to include("could not confirm the installation")
      expect(response).to redirect_to(repositories_path)
    end

    it "records nothing when GitHub cannot be reached" do
      user = sign_in_via_github(installation: false)
      allow(GithubAppUserAuthorization).to receive(:installations)
        .and_raise(GithubApi::Unavailable, "down")

      get github_installation_callback_path, params: { code: "abc" }

      expect(user.github_installations).to be_empty
      expect(flash[:alert]).to include("could not confirm the installation")
    end

    # Idempotent, because the flow is: GitHub sends a user here every time they pass through it,
    # including when they merely change which repositories are selected. A second visit updates the
    # row rather than failing on the uniqueness index or growing a duplicate.
    it "is idempotent across repeat visits, and refreshes what it knows" do
      user = sign_in_via_github(installation: false)
      stub_user_installations({ installation_id: 777, account_login: "acme" })
      get github_installation_callback_path, params: { code: "abc" }

      stub_user_installations({ installation_id: 777, account_login: "acme-renamed" })
      expect { get github_installation_callback_path, params: { code: "def" } }
        .not_to change { user.github_installations.count }

      expect(user.github_installations.first.account_login).to eq("acme-renamed")
    end

    it "returns the user to where they started" do
      sign_in_via_github(installation: false)
      stub_user_installations({ installation_id: 777, account_login: "acme" })

      get github_installation_callback_path, params: { code: "abc", state: "/repositories/new" }

      expect(response).to redirect_to("/repositories/new")
    end

    # The last hop of an authorization flow is the single most attractive open redirect an app has,
    # and `state` has been out to github.com and back.
    it "discards a return path that leaves this site" do
      sign_in_via_github(installation: false)
      stub_user_installations({ installation_id: 777, account_login: "acme" })

      get github_installation_callback_path, params: { code: "abc", state: "https://evil.example" }
      expect(response).to redirect_to(repositories_path)

      get github_installation_callback_path, params: { code: "abc", state: "//evil.example" }
      expect(response).to redirect_to(repositories_path)
    end

    # GitHub confirmed the authorization and reported no installations, which is what cancelling out
    # of the repository picker looks like. Telling that user "repositories connected" would be
    # telling them something false.
    it "says so when GitHub confirms the authorization but reports no installations" do
      sign_in_via_github(installation: false)
      stub_user_installations

      get github_installation_callback_path, params: { code: "abc" }

      expect(flash[:notice]).to eq("GitHub reported no SpecGuard installations for your account yet.")
    end

    it "requires a signed-in user" do
      get github_installation_callback_path, params: { code: "abc" }

      expect(response).to redirect_to(root_path)
    end
  end

  describe "sign-in itself" do
    # Sign-in connects NOTHING now, and that is worth pinning rather than assuming: under the OAuth
    # path it did, because the callback banked a `repo`-scoped token, and a reader who remembers
    # that would reasonably expect a signed-in user to be able to register something.
    it "leaves a signed-in user with nothing connected" do
      user = sign_in_via_github(installation: false)

      expect(user).not_to be_github_installed
      expect(user.github_installations).to be_empty
    end

    it "returns the user to where the sign-in was started from" do
      sign_in_via_github(origin: "/repositories/new")

      expect(response).to redirect_to("/repositories/new")
    end

    it "discards an origin that leaves this site" do
      sign_in_via_github(origin: "https://evil.example/phish")
      expect(response).to redirect_to(repositories_path)

      sign_in_via_github(origin: "//evil.example/phish")
      expect(response).to redirect_to(repositories_path)
    end

    it "falls back to the dashboard when there is no origin" do
      sign_in_via_github

      expect(response).to redirect_to(repositories_path)
      expect(flash[:notice]).to eq("Signed in as octocat.")
    end

    # Saying "Signed in as octocat" to somebody who was already octocat reads as though something
    # changed. Nothing did.
    it "says nothing when the same person re-authenticates" do
      sign_in_via_github
      sign_in_via_github

      expect(flash[:notice]).to be_nil
    end
  end
end
