# frozen_string_literal: true

# GitHub OAuth — the human sign-in path. (CI/agents use API keys instead; see ApiKey.)
#
# The client id/secret are secrets and are NOT committed. Provide them however you like:
#
#   export GITHUB_CLIENT_ID=...        # from https://github.com/settings/developers
#   export GITHUB_CLIENT_SECRET=...
#
# or via encrypted credentials (`bin/rails credentials:edit`):
#
#   github:
#     client_id: ...
#     client_secret: ...
#
# With neither set, the provider is still mounted with placeholder values so the app boots and the
# suite runs; a real sign-in attempt against GitHub will simply be rejected by GitHub.
# `SpecGuard::GithubOauth.configured?` reports whether real credentials are present, and the
# sign-in UI says so rather than dead-ending the user.
module SpecGuard
  module GithubOauth
    PLACEHOLDER = "specguard-oauth-not-configured"

    class << self
      def client_id
        ENV["GITHUB_CLIENT_ID"].presence || credential(:client_id) || PLACEHOLDER
      end

      def client_secret
        ENV["GITHUB_CLIENT_SECRET"].presence || credential(:client_secret) || PLACEHOLDER
      end

      def configured?
        client_id != PLACEHOLDER && client_secret != PLACEHOLDER
      end

      private

      def credential(key)
        Rails.application.credentials.dig(:github, key).presence
      rescue StandardError
        nil
      end
    end
  end
end

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
           SpecGuard::GithubOauth.client_id,
           SpecGuard::GithubOauth.client_secret,
           scope: "read:user,user:email"
end

# omniauth-rails_csrf_protection: the request phase must be a POST carrying an authenticity token.
OmniAuth.config.allowed_request_methods = [:post]
OmniAuth.config.silence_get_warning = true

# Never blow up the app on a provider error — route it to our failure handler instead.
OmniAuth.config.on_failure = proc { |env| SessionsController.action(:failure).call(env) }
