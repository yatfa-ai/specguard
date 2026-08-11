# frozen_string_literal: true

module OmniAuthHelpers
  DEFAULT_AUTH = {
    "provider" => "github",
    "uid" => "1001",
    "info" => {
      "nickname" => "octocat",
      "name" => "The Octocat",
      "email" => "octocat@example.com",
      "image" => "https://avatars.githubusercontent.com/u/1001"
    },
    # The token and the scopes it carries — the two halves SessionsController banks, and what every
    # repository read then rests on. Present by default at the *elevated* scope, so a spec about
    # API keys or sharing gets a user who can register a repository without having to describe an
    # OAuth grant it does not care about. Same default, same reason, as the permissive
    # FakeGithubApi in spec/support/github_api.rb.
    #
    # A spec about the authorization flow itself overrides it:
    #
    #   sign_in_via_github(scope: SpecGuard::GithubOauth::SIGN_IN_SCOPE)  # signed in, not connected
    #   sign_in_via_github(credentials: nil)                              # callback with no token
    "credentials" => { "token" => "gho_test_token" },
    "extra" => { "scope" => "repo,read:user,user:email" }
  }.freeze

  def mock_github_auth(overrides = {})
    payload = DEFAULT_AUTH.deep_dup
    payload["uid"] = overrides[:uid].to_s if overrides.key?(:uid)
    payload["info"].merge!((overrides[:info] || {}).transform_keys(&:to_s))
    payload["extra"]["scope"] = overrides[:scope] if overrides.key?(:scope)

    if overrides.key?(:credentials)
      credentials = overrides[:credentials]
      credentials.nil? ? payload.delete("credentials") : payload["credentials"] = credentials.transform_keys(&:to_s)
    end

    auth = OmniAuth::AuthHash.new(payload)
    OmniAuth.config.mock_auth[:github] = auth
    Rails.application.env_config["omniauth.auth"] = auth
    auth
  end

  # Drives the real callback action, so this exercises the same code path a browser would.
  #
  # `origin` is what the OmniAuth request phase stashes for the callback to read back — the
  # mechanism that returns a user to the page they were on when they authorized. Set it to
  # exercise where an authorization lands; leave it out and the callback falls back to the
  # dashboard exactly as a plain sign-in does.
  def sign_in_via_github(overrides = {})
    mock_github_auth(overrides)
    Rails.application.env_config["omniauth.origin"] = overrides[:origin] if overrides.key?(:origin)

    get "/auth/github/callback"
    User.find_by(github_uid: OmniAuth.config.mock_auth[:github]["uid"].to_s)
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
