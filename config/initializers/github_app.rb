# frozen_string_literal: true

# The SpecGuard GitHub App — how a user connects repositories.
#
# Connecting a repository is installing this App on it and picking it in GitHub's own repository
# picker. What SpecGuard may then read is decided by the App's declared permissions, and only
# someone who administers a repository can install an App on it — which is why membership of an
# installation is the whole of the ownership proof (see `InstallationRepositories`).
#
# The App requests **Metadata: read-only** and nothing else. That permission set is declared on the
# App itself on github.com when it is created; it is deliberately NOT mirrored, configured or
# asserted from this repository, because a copy here could only ever disagree with the authority.
# `Contents: read` is not requested: nothing in SpecGuard reads repository code — every spec-file
# path it holds arrives as rspec-plugin telemetry over an API key — and adding a permission later
# forces re-consent on every existing installation.
#
# ## Two App settings this code depends on
#
# Both are ticked on the App itself on github.com when it is created, and neither is assertable
# from here — but a reader of this file has to know they are load-bearing:
#
#   - **Setup URL** must be `<host>/github/installation/callback`, which is where GitHub returns a
#     user after they install or reconfigure (`GithubInstallationsController#callback`).
#   - **"Request user authorization (OAuth) during installation"** must be ON. It is what makes
#     GitHub send a `code` alongside `installation_id`, and that code is the ONLY thing that proves
#     the person arriving at the setup URL is entitled to the installation they arrived carrying.
#     Without it the callback is a URL anyone can type with somebody else's installation id in it.
#     `GithubAppUserAuthorization` states that argument in full; the callback fails closed when no
#     code arrives.
#
# ## Credentials
#
# Five values identify the App, and none of them is committed:
#
#   export GITHUB_APP_ID=123456                     # Settings → Developer settings → GitHub Apps
#   export GITHUB_APP_SLUG=specguard                # the app's URL name, for the install link
#   export GITHUB_APP_PRIVATE_KEY="$(cat key.pem)"  # the PEM it signs its JWTs with
#   export GITHUB_APP_CLIENT_ID=Iv1.…               # the App's own OAuth client, for the
#   export GITHUB_APP_CLIENT_SECRET=…               #   install-time code exchange
#
# or via encrypted credentials (`bin/rails credentials:edit`):
#
#   github_app:
#     app_id: ...
#     slug: ...
#     private_key: |
#       -----BEGIN RSA PRIVATE KEY-----
#       ...
#     client_id: ...
#     client_secret: ...
#
# The client id/secret are the App's OWN OAuth credentials and are not the ones in
# `SpecGuard::GithubOauth`: that is a separate OAuth App which still handles sign-in and still asks
# for identity alone. They are kept apart deliberately — sign-in is untouched by this slice, and an
# App whose credentials are mixed up with the sign-in App's fails in a way that takes sign-in with
# it.
#
# With none of them set the App is unconfigured and `configured?` says so, exactly as
# `SpecGuard::GithubOauth` does for sign-in: the app boots, the suite runs, and the connect UI
# explains what is missing rather than dead-ending the user at a GitHub URL that cannot work.
# Development and test never have real App credentials and nothing here may require them — the
# specs go through `GithubApi.factory`, and a developer who needs connected repositories seeds
# them from the console.
module SpecGuard
  module GithubApp
    PLACEHOLDER = "specguard-github-app-not-configured"

    # GitHub's own host, not `api.github.com`: installing is a thing a *person* does in a browser,
    # and the install and configure pages live on the website.
    GITHUB_HOST = "https://github.com"

    class << self
      def app_id = ENV["GITHUB_APP_ID"].presence || credential(:app_id) || PLACEHOLDER

      # The App's URL name — the `specguard` in github.com/apps/specguard. Distinct from `app_id`
      # because the numeric id names the App to the API and the slug names it to a browser, and
      # neither can be derived from the other.
      def slug = ENV["GITHUB_APP_SLUG"].presence || credential(:slug) || PLACEHOLDER

      # The PEM GitHub issued when the App was created, used to sign the short-lived JWT that mints
      # installation tokens (see `GithubAppCredentials`). ENV carries it with real newlines when
      # exported from a file; `\n` escapes are accepted too, because a private key routed through a
      # secrets manager or a CI variable frequently arrives that way and a key that differs from the
      # real one only in its line endings fails with an opaque OpenSSL error.
      def private_key
        raw = ENV["GITHUB_APP_PRIVATE_KEY"].presence || credential(:private_key)
        return PLACEHOLDER if raw.blank?

        raw.include?('\n') ? raw.gsub('\n', "\n") : raw
      end

      # The App's own OAuth client, used for exactly one exchange: turning the `code` GitHub sends
      # to the setup URL into a short-lived user token, so GitHub can be asked which installations
      # that user actually holds. See `GithubAppUserAuthorization`.
      def client_id = ENV["GITHUB_APP_CLIENT_ID"].presence || credential(:client_id) || PLACEHOLDER

      def client_secret = ENV["GITHUB_APP_CLIENT_SECRET"].presence || credential(:client_secret) || PLACEHOLDER

      # All five, because the flow needs all five: the install link needs the slug, the callback
      # needs the client pair to verify what came back, and reading repositories needs the app id
      # and private key. Reporting "configured" on a subset would move the failure from a sentence
      # on the connect page to a 500 halfway through the flow.
      def configured?
        [app_id, slug, private_key, client_id, client_secret].none? { |value| value == PLACEHOLDER }
      end

      # Where a user goes to install the App and choose repositories. GitHub renders the picker and
      # the consent screen from the App's own configuration; nothing about that page is built here.
      #
      # `state` is GitHub's own round-trip parameter: it is handed back to the App's setup URL
      # unchanged, which is how a user lands back where they started. It is opaque to GitHub and is
      # validated on the way back, never trusted — see `GithubInstallationsController#create`.
      def installation_url(state: nil)
        url = "#{GITHUB_HOST}/apps/#{ERB::Util.url_encode(slug)}/installations/new"
        state.present? ? "#{url}?#{URI.encode_www_form(state: state)}" : url
      end

      private

      def credential(key)
        Rails.application.credentials.dig(:github_app, key).presence
      rescue StandardError
        nil
      end
    end
  end
end
