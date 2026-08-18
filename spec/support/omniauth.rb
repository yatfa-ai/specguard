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
  # `installation:` records a GitHub App installation for the signed-in user, and defaults to one
  # for the reason the elevated-scope default existed before it: a spec about API keys or sharing
  # needs somebody who can register a repository and should not have to describe an installation
  # flow it does not care about.
  #
  # It is a SEPARATE step from the callback, and deliberately so — signing in no longer connects
  # anything, and a helper that hid that would let a spec claim the sign-in did it. A spec about the
  # gap between the two says `installation: false` and gets the state every user is really in the
  # moment they arrive.
  def sign_in_via_github(overrides = {})
    mock_github_auth(overrides)
    Rails.application.env_config["omniauth.origin"] = overrides[:origin] if overrides.key?(:origin)

    get "/auth/github/callback"

    user = User.find_by(github_uid: OmniAuth.config.mock_auth[:github]["uid"].to_s)
    install_for(user, overrides.fetch(:installation, DEFAULT_INSTALLATION_ID))
    user
  end

  private

  def install_for(user, installation)
    return user if user.nil? || installation == false || installation.nil?

    id = installation == true ? DEFAULT_INSTALLATION_ID : installation
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
