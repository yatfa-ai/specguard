# frozen_string_literal: true

require "rails_helper"

# Incremental authorization. Signing in and connecting repositories are two different asks of the
# same person, deliberately separated: a visitor who only ever looks at a dashboard is never asked
# for access to their repositories, and the broad scope is requested at the moment it is needed —
# the first registration — with the tradeoff stated on screen.
RSpec.describe "GitHub authorization", type: :request do
  describe "what each entry point asks for" do
    # The whole point of splitting the two. If sign-in asked for `repo`, every visitor would be
    # handing over read access to their private repositories to look at a public dashboard.
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

    # And carries the sign-in scopes along, because GitHub issues a token for exactly the scopes in
    # the request — asking for `repo` alone would trade the identity scopes away for it.
    it "asks for repository access only at the point of registering one" do
      sign_in_via_github(scope: SpecGuard::GithubOauth::SIGN_IN_SCOPE)

      get new_repository_path

      expect(response.body).to include("scope=repo%2Cread%3Auser%2Cuser%3Aemail")
      expect(response.body).to include("origin=%2Frepositories%2Fnew")
      expect(response.body).to include("SpecGuard will ask GitHub for access to your repositories")
    end
  end

  describe "the callback" do
    it "banks the token and the scopes GitHub actually granted" do
      user = sign_in_via_github

      expect(user.github_access_token).to eq("gho_test_token")
      expect(user.github_scopes).to include("repo")
      expect(user.github_token_updated_at).to be_present
      expect(user).to be_github_repository_access
    end

    # The column holds Active Record Encryption's envelope, never the token. A database dump is
    # the threat being addressed, so the assertion is against the raw column rather than the
    # attribute — reading the attribute back would pass either way.
    it "stores the token encrypted at rest" do
      user = sign_in_via_github

      stored = User.connection.select_value("SELECT github_access_token FROM users WHERE id = #{user.id}")
      expect(stored).to be_present
      expect(stored).not_to include("gho_test_token")
    end

    it "returns the user to where the authorization was started from" do
      sign_in_via_github(origin: "/repositories/new")

      expect(response).to redirect_to("/repositories/new")
    end

    # The last hop of an OAuth flow is the single most attractive open redirect an app has, and
    # `origin` is a value the user controls end to end.
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

    it "says the repositories are connected when a signed-in user comes back with the grant" do
      sign_in_via_github(scope: SpecGuard::GithubOauth::SIGN_IN_SCOPE)

      sign_in_via_github(scope: SpecGuard::GithubOauth::REPOSITORY_SCOPE)

      expect(flash[:notice]).to eq("GitHub repositories connected.")
    end

    # GitHub returns a perfectly valid token with narrower scopes when an organization's policy
    # blocks the grant. Without this the only symptom is an empty repository list on the next page
    # with nothing saying why.
    it "warns when a returning user came back without the repository grant" do
      sign_in_via_github(scope: SpecGuard::GithubOauth::SIGN_IN_SCOPE)

      sign_in_via_github(scope: SpecGuard::GithubOauth::SIGN_IN_SCOPE)

      expect(flash[:alert]).to include("did not grant repository access")
    end

    # A callback that carried no token is not evidence that the user revoked anything, and
    # clearing the stored one there would silently demote someone who had already connected.
    it "leaves an existing token alone when a callback carries none" do
      user = sign_in_via_github

      sign_in_via_github(credentials: nil)

      expect(user.reload.github_access_token).to eq("gho_test_token")
      expect(user).to be_github_repository_access
    end
  end
end
