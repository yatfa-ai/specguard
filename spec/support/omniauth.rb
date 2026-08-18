# frozen_string_literal: true

module OmniAuthHelpers
  # Identity, and nothing else — which is now the whole of what the sign-in callback consumes.
  #
  # There used to be `credentials` and `extra.scope` here, carrying a `repo`-scoped OAuth token that
  # `User.from_github_omniauth` banked and every repository read then rested on. Both are gone with
  # the scope: sign-in asks GitHub for a handle, an avatar and an email address, and repository
  # access is a GitHub App installation (`GithubInstallation`). A token in this hash would be
  # describing a thing the app no longer reads.
  DEFAULT_AUTH = {
    "provider" => "github",
    "uid" => "1001",
    "info" => {
      "nickname" => "octocat",
      "name" => "The Octocat",
      "email" => "octocat@example.com",
      "image" => "https://avatars.githubusercontent.com/u/1001"
    }
  }.freeze

  # The installation `sign_in_via_github` records by default. Matches `Builders#create_user`, so a
  # spec that signs in and a spec that builds a user describe the same connected user rather than
  # two subtly different ones.
  DEFAULT_INSTALLATION_ID = 5001

  # The credential the App flow hands back. A request spec's session can only be written by a
  # request, so this is what the stood-in code exchange returns rather than something written
  # straight into a cookie.
  DEFAULT_USER_TOKEN = "ghu_spec_user_token"

  def mock_github_auth(overrides = {})
    payload = DEFAULT_AUTH.deep_dup
    payload["uid"] = overrides[:uid].to_s if overrides.key?(:uid)
    payload["info"].merge!((overrides[:info] || {}).transform_keys(&:to_s))

    auth = OmniAuth::AuthHash.new(payload)
    OmniAuth.config.mock_auth[:github] = auth
    Rails.application.env_config["omniauth.auth"] = auth
    auth
  end

  # Drives the real callback action, so this exercises the same code path a browser would.
  #
  # `origin` is what the OmniAuth request phase stashes for the callback to read back — the
  # mechanism that returns a user to the page they were on when they signed in. Set it to exercise
  # where a sign-in lands; leave it out and the callback falls back to the dashboard.
  #
  # `installation:` connects a GitHub App installation for the signed-in user, and defaults to one
  # for the reason the elevated-scope default existed before it: a spec about API keys or sharing
  # needs somebody who can register a repository and should not have to describe an installation
  # flow it does not care about.
  #
  # It is a SEPARATE step from the sign-in callback, and deliberately so — signing in no longer
  # connects anything, and a helper that hid that would let a spec claim the sign-in did it. A spec
  # about the gap between the two says `installation: false` and gets the state every user is really
  # in the moment they arrive.
  #
  # `authorize: false` connects the installation WITHOUT putting a credential in the session — the
  # state a returning user is in at the start of a new browser session, when the App is installed
  # and there is nothing to read it with. That is a different missing thing from `installation:
  # false`, and it has its own answer on screen.
  def sign_in_via_github(overrides = {})
    mock_github_auth(overrides)
    Rails.application.env_config["omniauth.origin"] = overrides[:origin] if overrides.key?(:origin)

    get "/auth/github/callback"

    user = User.find_by(github_uid: OmniAuth.config.mock_auth[:github]["uid"].to_s)
    connect_github_app(user, overrides.fetch(:installation, DEFAULT_INSTALLATION_ID),
                       authorize: overrides.fetch(:authorize, true))
    user
  end

  # Puts a GitHub credential in the session by driving the App's own callback.
  #
  # The session is the only place that credential lives (`GithubUserSession`), and a request spec's
  # session can only be written by a request — so this goes through the real controller rather than
  # reaching past it. Exactly two things are stood in for, and only two: the App's credentials,
  # which no test environment has, and the code exchange, which would be a network call. Everything
  # between them is the code a browser would run.
  #
  # `state` sends the redirect to `/up` rather than to the dashboard. That is not cosmetic: the
  # redirect is FOLLOWED, and following it is what CONSUMES the "Connected …" flash this leaves
  # behind, so a spec's own first request sees the flash its own action set rather than this
  # helper's. `/up` is the cheapest page in the app to render, and this runs on every signed-in
  # request spec in the suite.
  def authorize_github_app(installations: [[DEFAULT_INSTALLATION_ID, "acme"]],
                           token: DEFAULT_USER_TOKEN, expires_at: 1.hour.from_now)
    rows = Array(installations).map do |id, login|
      GithubAppUserAuthorization::Installation.new(installation_id: id, account_login: login)
    end
    authorization = GithubAppUserAuthorization::Authorization.new(token: token, expires_at: expires_at,
                                                                  installations: rows)

    allow(SpecGuard::GithubApp).to receive(:configured?).and_return(true)
    allow(GithubAppUserAuthorization).to receive(:authorize).and_return(authorization)

    get "/github/installation/callback", params: { code: "spec-code", state: "/up" }
    follow_redirect!
  ensure
    allow(SpecGuard::GithubApp).to receive(:configured?).and_call_original
    allow(GithubAppUserAuthorization).to receive(:authorize).and_call_original
  end

  private

  def connect_github_app(user, installation, authorize:)
    return user if user.nil? || installation == false || installation.nil?

    id = installation == true ? DEFAULT_INSTALLATION_ID : installation
    return record_installation(user, id) unless authorize

    authorize_github_app(installations: [[id, "acme"]])
    user
  end

  # The row without the credential — what a session that has expired still has to work from.
  def record_installation(user, id)
    GithubInstallation.record(user: user, installation_id: id, account_login: "acme")
    user
  end
end

RSpec.configure do |config|
  config.include OmniAuthHelpers, type: :request

  config.before(:suite) { OmniAuth.config.test_mode = true }

  config.after(type: :request) do
    OmniAuth.config.mock_auth[:github] = nil
    Rails.application.env_config.delete("omniauth.auth")
    Rails.application.env_config.delete("omniauth.origin")
  end
end
