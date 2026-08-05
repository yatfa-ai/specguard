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
    }
  }.freeze

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
  def sign_in_via_github(overrides = {})
    mock_github_auth(overrides)
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
  end
end
