# frozen_string_literal: true

require "rails_helper"

# Connecting repositories, end to end through the controller.
#
# Signing in and connecting repositories are two different asks of the same person, and after
# SPGD-424 they are two different MECHANISMS: sign-in is OAuth and asks for identity alone, and
# connecting repositories is installing a GitHub App. Installing it is what makes a repository
# READABLE; whether this particular user may register it is a second question, answered per user
# against their own credential (`InstallationRepositories`). A visitor who only ever looks at a
# dashboard is never asked for anything about their repositories, and nothing in the app can read
# one without an installation.
RSpec.describe "GitHub App installation", type: :request do
  # Both halves of the flow need the App to look configured. Development, test and CI never have
  # real App credentials — that is the whole reason `configured?` exists — so a spec about the flow
  # says so rather than requiring a private key to exist.
  def with_configured_app
    allow(SpecGuard::GithubApp).to receive_messages(
      configured?: true, slug: "specguard", client_id: "Iv1.test", client_secret: "secret"
    )
  end

  # The one seam the callback rests on: GitHub's own answer to "who is this and what can they
  # reach", plus the credential every later read is made with. Stubbed at the service rather than
  # over HTTP, the same discipline `GithubApi.factory` follows — no spec reaches github.com and none
  # needs a real code to exchange.
  def stub_user_authorization(*installations, token: "ghu_from_callback", expires_at: 1.hour.from_now)
    rows = installations.map do |attrs|
      GithubAppUserAuthorization::Installation.new(
        installation_id: attrs.fetch(:installation_id), account_login: attrs[:account_login]
      )
    end

    allow(GithubAppUserAuthorization).to receive(:authorize).and_return(
      GithubAppUserAuthorization::Authorization.new(token: token, expires_at: expires_at,
                                                    installations: rows)
    )
  end

  describe "what each entry point asks for" do
    # The whole point of keeping the two apart. If sign-in asked for `repo`, every visitor would be
    # handing over read and write access to their private repositories in order to look at a
    # dashboard.
    # @intent: {"entity": "GET /", "action": "ask identity scopes only", "behavior": "the sign-in scope constant is read:user,user:email without repo, and the home page form posts to /auth/github with no scope parameter", "layer": "request"}
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
    # @intent: {"entity": "User", "action": "hold no repository token", "behavior": "SpecGuard::GithubOauth defines no REPOSITORY_SCOPE constant and the users table carries neither github_access_token nor github_token_scopes", "layer": "request"}
    it "has no repository scope left to request" do
      expect(SpecGuard::GithubOauth.constants).not_to include(:REPOSITORY_SCOPE)
      expect(User.column_names).not_to include("github_access_token", "github_token_scopes")
    end

    # Registering is where the offer appears, and what it offers is an installation rather than a
    # broader grant.
    # @intent: {"entity": "GET /repositories/new", "action": "offer installation flow", "behavior": "the new-repository page renders a form posting to /github/installation with return_to the new-repository path, and copy describing read-only access to repository metadata", "layer": "request"}
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
    # @intent: {"entity": "GET /repositories/new", "action": "explain unconfigured app", "behavior": "with the App unconfigured the new-repository page explains The SpecGuard GitHub App is not configured, names GITHUB_APP_SLUG, and renders no installation form", "layer": "request"}
    it "explains itself rather than offering a button an unconfigured instance cannot honour" do
      sign_in_via_github(installation: false)

      get new_repository_path

      expect(response.body).to include("The SpecGuard GitHub App is not configured")
      expect(response.body).to include("GITHUB_APP_SLUG")
      expect(response.body).not_to include('action="/github/installation')
    end
  end

  describe "POST /github/installation" do
    before { with_configured_app }

    # @intent: {"entity": "POST /github/installation", "action": "redirect to installation flow", "behavior": "posting return_to /repositories/new redirects to github.com/apps/specguard/installations/new with state=%2Frepositories%2Fnew", "layer": "request"}
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
    # @intent: {"entity": "POST /github/installation", "action": "refuse offsite return path", "behavior": "return_to values of https://evil.example/phish, //evil.example/phish and the backslash variant each redirect carrying the fallback state=%2Frepositories", "layer": "request"}
    it "refuses to carry a return path that leaves this site" do
      sign_in_via_github(installation: false)
      carrying_the_fallback =
        "https://github.com/apps/specguard/installations/new?state=%2Frepositories"

      post github_installation_path, params: { return_to: "https://evil.example/phish" }
      expect(response).to redirect_to(carrying_the_fallback)

      post github_installation_path, params: { return_to: "//evil.example/phish" }
      expect(response).to redirect_to(carrying_the_fallback)

      # The same trick with the slash a few user agents normalise back off-site.
      post github_installation_path, params: { return_to: "/\\evil.example" }
      expect(response).to redirect_to(carrying_the_fallback)
    end

    # @intent: {"entity": "POST /github/installation", "action": "require signed-in user", "behavior": "an unsigned POST redirects to the root path", "layer": "request"}
    it "requires a signed-in user" do
      post github_installation_path

      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /github/installation/callback" do
    before { with_configured_app }

    # @intent: {"entity": "GET /github/installation/callback", "action": "record reported installations", "behavior": "a confirmed exchange grows github_installations from 0 to 2 rows for ids 777 and 888 and flashes Connected acme and beta.", "layer": "request"}
    it "records every installation GitHub reports for this user" do
      user = sign_in_via_github(installation: false)
      stub_user_authorization({ installation_id: 777, account_login: "acme" },
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
    # @intent: {"entity": "GET /github/installation/callback", "action": "ignore url installation id", "behavior": "a URL carrying installation_id 999999 records only the 777 GitHub reports, never the forged id", "layer": "request"}
    it "records what GitHub reports, never the installation id in the URL" do
      user = sign_in_via_github(installation: false)
      stub_user_authorization({ installation_id: 777, account_login: "acme" })

      get github_installation_callback_path, params: { installation_id: 999_999, code: "abc" }

      expect(user.github_installations.pluck(:installation_id)).to eq([777])
    end

    # A forged callback carries no usable code, so the exchange fails and nothing is recorded. The
    # user is exactly as connected as they were before, which is the only safe reading of "GitHub
    # would not confirm this".
    # @intent: {"entity": "GET /github/installation/callback", "action": "fail closed on refusal", "behavior": "an Unauthorized from the code exchange leaves github_installations empty, flashes could not confirm the installation, and redirects to /repositories", "layer": "request"}
    it "records nothing when GitHub will not confirm the authorization" do
      user = sign_in_via_github(installation: false)
      allow(GithubAppUserAuthorization).to receive(:authorize)
        .and_raise(GithubApi::Unauthorized, "bad code")

      get github_installation_callback_path, params: { installation_id: 777 }

      expect(user.github_installations).to be_empty
      expect(flash[:alert]).to include("could not confirm the installation")
      expect(response).to redirect_to(repositories_path)
    end

    # @intent: {"entity": "GET /github/installation/callback", "action": "fail closed when unreachable", "behavior": "an Unavailable GitHub leaves no installation rows and flashes could not confirm the installation", "layer": "request"}
    it "records nothing when GitHub cannot be reached" do
      user = sign_in_via_github(installation: false)
      allow(GithubAppUserAuthorization).to receive(:authorize)
        .and_raise(GithubApi::Unavailable, "down")

      get github_installation_callback_path, params: { code: "abc" }

      expect(user.github_installations).to be_empty
      expect(flash[:alert]).to include("could not confirm the installation")
    end

    # The two above stub the service and raise, so they pin the CONTROLLER's handling of a refusal
    # they were handed. This one refuses to stub it: the exchange runs for real against a token
    # endpoint answering 200 with a JSON ARRAY, which is a body `GithubAppUserAuthorization#decode`
    # passes through untouched because the installation and repository walks need arrays. Reading
    # `["error"]` off one raised a `TypeError`, which is not a `GithubApi::Error` and so walked
    # straight past the rescue below into a 500 error page on the OAuth callback — with the
    # diagnostic never logged. Asserted end to end because that is where the cost was paid.
    # @intent: {"entity": "GET /github/installation/callback", "action": "survive json array reply", "behavior": "a 200 token endpoint answering a JSON array redirects to /repositories with an alert and a logged warning, records nothing, keeps no session credential, and stops after exactly one HTTP request", "layer": "request"}
    it "redirects rather than 500ing when GitHub answers the exchange with a JSON array" do
      user = sign_in_via_github(installation: false)
      with_configured_app
      token_endpoint = Net::HTTPOK.new("1.1", "200", "OK")
      allow(token_endpoint).to receive(:body).and_return("[]")
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_return(token_endpoint)
      allow(Net::HTTP).to receive(:start).and_yield(http)
      allow(Rails.logger).to receive(:warn)

      get github_installation_callback_path, params: { installation_id: 777, code: "abc" }

      expect(response).to redirect_to(repositories_path)
      expect(flash[:alert]).to include("could not confirm the installation")
      expect(Rails.logger).to have_received(:warn).with(/GithubApi::Unauthorized.*no access token/)

      # Fail-closed, asserted rather than inferred from the order the controller happens to run in:
      # no installation recorded, and no credential in the session for a later page to read with.
      expect(user.github_installations).to be_empty
      expect(session["github_user_token"]).to be_nil

      # And it stopped at the exchange — the identity read and the listing walk never happened.
      expect(http).to have_received(:request).once
    end

    # Idempotent, because the flow is: GitHub sends a user here every time they pass through it,
    # including when they merely change which repositories are selected. A second visit updates the
    # row rather than failing on the uniqueness index or growing a duplicate.
    # @intent: {"entity": "GET /github/installation/callback", "action": "stay idempotent", "behavior": "a second callback for installation 777 adds no row and refreshes its account_login to acme-renamed", "layer": "request"}
    it "is idempotent across repeat visits, and refreshes what it knows" do
      user = sign_in_via_github(installation: false)
      stub_user_authorization({ installation_id: 777, account_login: "acme" })
      get github_installation_callback_path, params: { code: "abc" }

      stub_user_authorization({ installation_id: 777, account_login: "acme-renamed" })
      expect { get github_installation_callback_path, params: { code: "def" } }
        .not_to change { user.github_installations.count }

      expect(user.github_installations.first.account_login).to eq("acme-renamed")
    end

    # @intent: {"entity": "GET /github/installation/callback", "action": "return to start", "behavior": "a callback carrying state=/repositories/new redirects back to /repositories/new", "layer": "request"}
    it "returns the user to where they started" do
      sign_in_via_github(installation: false)
      stub_user_authorization({ installation_id: 777, account_login: "acme" })

      get github_installation_callback_path, params: { code: "abc", state: "/repositories/new" }

      expect(response).to redirect_to("/repositories/new")
    end

    # The last hop of an authorization flow is the single most attractive open redirect an app has,
    # and `state` has been out to github.com and back.
    # @intent: {"entity": "GET /github/installation/callback", "action": "discard offsite state", "behavior": "state values of https://evil.example, //evil.example and the backslash variant each redirect to /repositories", "layer": "request"}
    it "discards a return path that leaves this site" do
      sign_in_via_github(installation: false)
      stub_user_authorization({ installation_id: 777, account_login: "acme" })

      get github_installation_callback_path, params: { code: "abc", state: "https://evil.example" }
      expect(response).to redirect_to(repositories_path)

      get github_installation_callback_path, params: { code: "abc", state: "//evil.example" }
      expect(response).to redirect_to(repositories_path)

      # The same trick with the slash a few user agents normalise back off-site.
      get github_installation_callback_path, params: { code: "abc", state: "/\\evil.example" }
      expect(response).to redirect_to(repositories_path)
    end

    # GitHub confirmed the authorization and reported no installations, which is what cancelling out
    # of the repository picker looks like. Telling that user "repositories connected" would be
    # telling them something false.
    # @intent: {"entity": "GET /github/installation/callback", "action": "report no installations", "behavior": "a confirmed authorization reporting no installations flashes that GitHub reported no SpecGuard installations for your account yet", "layer": "request"}
    it "says so when GitHub confirms the authorization but reports no installations" do
      sign_in_via_github(installation: false)
      stub_user_authorization

      get github_installation_callback_path, params: { code: "abc" }

      expect(flash[:notice]).to eq("GitHub reported no SpecGuard installations for your account yet.")
    end

    # @intent: {"entity": "GET /github/installation/callback", "action": "require signed-in user", "behavior": "an anonymous callback redirects to the root path", "layer": "request"}
    it "requires a signed-in user" do
      get github_installation_callback_path, params: { code: "abc" }

      expect(response).to redirect_to(root_path)
    end

    # The credential half of the callback, and the reason the callback exists at all now: what comes
    # back is not only "which installations" but the token that reads them. Asserted through what the
    # session then makes possible rather than by reading the cookie, because the cookie is an
    # implementation detail and the capability is the claim.
    # @intent: {"entity": "GET /github/installation/callback", "action": "keep session credential", "behavior": "the callback keeps the token so a following GET /repositories/new lists acme/api from the installation", "layer": "request"}
    it "keeps the credential for the session, so the next page can list repositories" do
      sign_in_via_github(installation: false)
      stub_github(repos: [github_repo("acme/api")])
      stub_user_authorization({ installation_id: 777, account_login: "acme" })

      get github_installation_callback_path, params: { code: "abc" }
      get new_repository_path

      expect(response.body).to include("acme/api")
    end

    # An expired credential is as good as none, and it must be treated as such BEFORE it is used
    # rather than after GitHub rejects it a round trip later.
    # @intent: {"entity": "GET /github/installation/callback", "action": "drop expired credential", "behavior": "a credential expired an hour ago leaves /repositories/new without acme/api and showing Reconnect to GitHub", "layer": "request"}
    it "stops using a credential once it has expired" do
      sign_in_via_github(installation: false)
      stub_github(repos: [github_repo("acme/api")])
      stub_user_authorization({ installation_id: 777, account_login: "acme" },
                              expires_at: 1.hour.ago)

      get github_installation_callback_path, params: { code: "abc" }
      get new_repository_path

      expect(response.body).not_to include("acme/api")
      expect(response.body).to include("Reconnect to GitHub")
    end

    # Two callbacks racing — a double-click on GitHub's redirect, a browser retry — both find no row
    # and both insert. The unique index catches the loser, and the loss of that race must read as
    # "the row exists", which is all the caller wanted, rather than as a 500 on the one flow whose
    # selling point is that repeating it is safe.
    # @intent: {"entity": "GET /github/installation/callback", "action": "survive race loss", "behavior": "a RecordNotUnique raised on the first save! is absorbed, the response redirects to /repositories with installation 777 recorded once", "layer": "request"}
    it "survives losing the race to a concurrent callback" do
      user = sign_in_via_github(installation: false)
      stub_user_authorization({ installation_id: 777, account_login: "acme" })

      # The first `save!` raises as though a concurrent request inserted the row a moment earlier;
      # the row is really there, so the retry finds it.
      first = true
      allow_any_instance_of(GithubInstallation).to receive(:save!).and_wrap_original do |original, *args|
        original.call(*args)
        next unless first

        first = false
        raise ActiveRecord::RecordNotUnique, "duplicate key"
      end

      get github_installation_callback_path, params: { code: "abc" }

      expect(response).to redirect_to(repositories_path)
      expect(user.github_installations.pluck(:installation_id)).to eq([777])
    end
    # The callback is a GET, so Rails applies no CSRF check to it and `state` is a return path
    # rather than a nonce — which means a signed-in user can be MADE to load this URL carrying a
    # `code` an attacker minted in their own browser for their own GitHub account and deliberately
    # left unredeemed. So the exchange is bound to the identity the session already claims, and the
    # controller is what supplies it.
    # @intent: {"entity": "GET /github/installation/callback", "action": "bind code to identity", "behavior": "the code exchange is invoked with the signed-in user's own github_uid alongside the code", "layer": "request"}
    it "binds the exchange to the signed-in user's own GitHub identity" do
      user = sign_in_via_github(installation: false)
      stub_user_authorization({ installation_id: 777, account_login: "acme" })

      get github_installation_callback_path, params: { code: "abc" }

      expect(GithubAppUserAuthorization).to have_received(:authorize)
        .with(code: "abc", github_uid: user.github_uid)
    end

    # And when GitHub says the code belongs to somebody else, nothing at all is kept: no
    # installation row, and no credential for the next page to read with.
    # @intent: {"entity": "GET /github/installation/callback", "action": "reject foreign code", "behavior": "a code belonging to another account records no rows, flashes could not confirm the installation, and leaves /repositories/new showing Reconnect to GitHub even with a row planted", "layer": "request"}
    it "records nothing and keeps no credential when the code belongs to another account" do
      user = sign_in_via_github(installation: false)
      allow(GithubAppUserAuthorization).to receive(:authorize)
        .and_raise(GithubApi::Unauthorized, "GitHub says that authorization belongs to a different account.")

      get github_installation_callback_path, params: { installation_id: 777, code: "planted" }

      expect(user.github_installations).to be_empty
      expect(flash[:alert]).to include("could not confirm the installation")

      # Not merely unrecorded — unusable. The next page has nothing to read GitHub with.
      GithubInstallation.record(user: user, installation_id: 777, account_login: "acme")
      get new_repository_path
      expect(response.body).to include("Reconnect to GitHub")
    end
  end

  # The smaller of the two ways out to GitHub. A session that has no credential needs one, and
  # walking somebody back through the repository picker to get it would be asking them to re-answer
  # a question they have already answered.
  describe "POST /github/installation/authorize" do
    before { with_configured_app }

    # @intent: {"entity": "POST /github/installation/authorize", "action": "redirect to authorize endpoint", "behavior": "posting return_to /repositories/new redirects to github.com/login/oauth/authorize with client_id=Iv1.test and state=%2Frepositories%2Fnew", "layer": "request"}
    it "sends the user to GitHub's user-authorization endpoint, not the installation picker" do
      sign_in_via_github(installation: false)

      post github_installation_authorize_path, params: { return_to: "/repositories/new" }

      expect(response).to redirect_to(
        "https://github.com/login/oauth/authorize?client_id=Iv1.test&state=%2Frepositories%2Fnew"
      )
    end

    # @intent: {"entity": "POST /github/installation/authorize", "action": "refuse offsite return path", "behavior": "offsite return_to values each redirect to the authorize URL carrying the fallback state=%2Frepositories", "layer": "request"}
    it "refuses to carry a return path that leaves this site" do
      sign_in_via_github(installation: false)
      carrying_the_fallback =
        "https://github.com/login/oauth/authorize?client_id=Iv1.test&state=%2Frepositories"

      post github_installation_authorize_path, params: { return_to: "https://evil.example/phish" }
      expect(response).to redirect_to(carrying_the_fallback)

      post github_installation_authorize_path, params: { return_to: "//evil.example/phish" }
      expect(response).to redirect_to(carrying_the_fallback)

      # The same trick with the slash a few user agents normalise back off-site.
      post github_installation_authorize_path, params: { return_to: "/\\evil.example" }
      expect(response).to redirect_to(carrying_the_fallback)
    end

    # @intent: {"entity": "POST /github/installation/authorize", "action": "require signed-in user", "behavior": "an anonymous POST redirects to the root path", "layer": "request"}
    it "requires a signed-in user" do
      post github_installation_authorize_path

      expect(response).to redirect_to(root_path)
    end

    # The whole round trip: a user whose session has no credential presses the button, GitHub sends
    # them back through the callback, and the page they came from now lists their repositories.
    # @intent: {"entity": "POST /github/installation/authorize", "action": "restore credential session", "behavior": "a session with no credential goes from /repositories/new showing Reconnect to GitHub to listing acme/api after the round trip through the callback", "layer": "request"}
    it "restores a session that had no credential" do
      sign_in_via_github(authorize: false)
      stub_github(repos: [github_repo("acme/api")])

      get new_repository_path
      expect(response.body).to include("Reconnect to GitHub")
      expect(response.body).not_to include("acme/api")

      stub_user_authorization({ installation_id: OmniAuthHelpers::DEFAULT_INSTALLATION_ID,
                                account_login: "acme" })
      get github_installation_callback_path, params: { code: "abc", state: "/repositories/new" }
      get new_repository_path

      expect(response.body).to include("acme/api")
    end
  end

  describe "sign-in itself" do
    # Sign-in connects NOTHING now, and that is worth pinning rather than assuming: under the OAuth
    # path it did, because the callback banked a `repo`-scoped token, and a reader who remembers
    # that would reasonably expect a signed-in user to be able to register something.
    # @intent: {"entity": "User", "action": "connect nothing at sign-in", "behavior": "after sign-in the user is not github_installed and has no github_installations rows", "layer": "request"}
    it "leaves a signed-in user with nothing connected" do
      user = sign_in_via_github(installation: false)

      expect(user).not_to be_github_installed
      expect(user.github_installations).to be_empty
    end

    # @intent: {"entity": "User", "action": "return to origin", "behavior": "a sign-in begun from /repositories/new redirects back to /repositories/new", "layer": "request"}
    it "returns the user to where the sign-in was started from" do
      sign_in_via_github(origin: "/repositories/new", installation: false)

      expect(response).to redirect_to("/repositories/new")
    end

    # @intent: {"entity": "User", "action": "discard offsite origin", "behavior": "origins of https://evil.example/phish, //evil.example/phish and the backslash variant each redirect to /repositories", "layer": "request"}
    it "discards an origin that leaves this site" do
      sign_in_via_github(origin: "https://evil.example/phish", installation: false)
      expect(response).to redirect_to(repositories_path)

      sign_in_via_github(origin: "//evil.example/phish", installation: false)
      expect(response).to redirect_to(repositories_path)

      # The same trick with the slash a few user agents normalise back off-site.
      sign_in_via_github(origin: "/\\evil.example", installation: false)
      expect(response).to redirect_to(repositories_path)
    end

    # @intent: {"entity": "User", "action": "fallback to dashboard", "behavior": "an originless sign-in redirects to /repositories and flashes the Signed in as octocat notice", "layer": "request"}
    it "falls back to the dashboard when there is no origin" do
      sign_in_via_github(installation: false)

      expect(response).to redirect_to(repositories_path)
      expect(flash[:notice]).to eq("Signed in as octocat.")
    end

    # Saying "Signed in as octocat" to somebody who was already octocat reads as though something
    # changed. Nothing did.
    # @intent: {"entity": "User", "action": "stay silent on re-auth", "behavior": "a second consecutive sign-in of the same person sets no flash notice", "layer": "request"}
    it "says nothing when the same person re-authenticates" do
      sign_in_via_github(installation: false)
      sign_in_via_github(installation: false)

      expect(flash[:notice]).to be_nil
    end
  end
end
