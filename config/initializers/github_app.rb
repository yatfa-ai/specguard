# frozen_string_literal: true

# The SpecGuard GitHub App — how a user connects repositories.
#
# Connecting a repository is installing this App on it and picking it in GitHub's own repository
# picker. What SpecGuard may then read is decided by the App's declared permissions.
#
# Installing the App is a NECESSARY condition for registering a repository and not a sufficient
# one. Only somebody who administers a repository can install an App on it — but the person who
# installed it is not the only person who can later READ it: GitHub lets any member of an
# organization see that organization's installation. So membership of an installation says a
# repository was deliberately handed to SpecGuard by SOMEBODY, and says nothing about the person
# looking at it now. The second half of the question — does THIS user administer THIS repository —
# is answered separately and against the user's own credential; see `InstallationRepositories`.
#
# The App requests **Metadata: read-only** and nothing else. That permission set is declared on the
# App itself on github.com when it is created; it is deliberately NOT mirrored, configured or
# asserted from this repository, because a copy here could only ever disagree with the authority.
# `Contents: read` is not requested: nothing in SpecGuard reads repository code — every spec-file
# path it holds arrives as rspec-plugin telemetry over an API key — and adding a permission later
# forces re-consent on every existing installation.
#
# ## Three App settings this code depends on
#
# All are set on the App itself on github.com when it is created, and none is assertable from here —
# but a reader of this file has to know they are load-bearing:
#
#   - **Callback URL** and **Setup URL** must both be `<host>/github/installation/callback`
#     (`GithubInstallationsController#callback`). GitHub uses the callback URL when it returns a
#     user carrying a `code` and the setup URL when it returns them without one; pointing both at
#     the same action means there is one place that reads what came back rather than two that can
#     disagree.
#   - **"Request user authorization (OAuth) during installation"** must be ON. It is what makes
#     GitHub send a `code` alongside `installation_id`, and that code is the ONLY thing that proves
#     the person arriving is entitled to the installation they arrived carrying — and the only way
#     SpecGuard ever obtains a credential that speaks for the user rather than for the App.
#     `GithubAppUserAuthorization` states that argument in full; the callback fails closed when no
#     code arrives.
#
# ## Credentials
#
# Three values identify the App, and none of them is committed:
#
#   export GITHUB_APP_SLUG=specguard                # the app's URL name, for the install link
#   export GITHUB_APP_CLIENT_ID=Iv1.…               # the App's own OAuth client, for the
#   export GITHUB_APP_CLIENT_SECRET=…               #   user code exchange
#
# or via encrypted credentials (`bin/rails credentials:edit`):
#
#   github_app:
#     slug: ...
#     client_id: ...
#     client_secret: ...
#
# There is deliberately no App id and no private key here. Those exist to mint an INSTALLATION
# access token — a credential that speaks for the App across everything the installation reaches —
# and SpecGuard has no question such a credential can answer: every question it asks is about one
# particular user's access, and is asked with that user's own short-lived token. Not holding the
# App's private key at all is a smaller thing to protect than holding one and using it carefully.
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

    # GitHub's own host, not `api.github.com`: installing and authorizing are things a *person* does
    # in a browser, and those pages live on the website.
    GITHUB_HOST = "https://github.com"

    class << self
      # The App's URL name — the `specguard` in github.com/apps/specguard. It names the App to a
      # browser, which is the only thing this app ever needs to name it to.
      def slug = ENV["GITHUB_APP_SLUG"].presence || credential(:slug) || PLACEHOLDER

      # The App's own OAuth client, used for exactly one thing: turning a `code` GitHub sends back
      # into a short-lived user-to-server token, so GitHub can be asked what that user may reach.
      # See `GithubAppUserAuthorization`.
      def client_id = ENV["GITHUB_APP_CLIENT_ID"].presence || credential(:client_id) || PLACEHOLDER

      def client_secret = ENV["GITHUB_APP_CLIENT_SECRET"].presence || credential(:client_secret) || PLACEHOLDER

      # All three, because the flow needs all three: the install and authorize links need the slug,
      # and reading anything at all needs the client pair to exchange the code that came back.
      # Reporting "configured" on a subset would move the failure from a sentence on the connect
      # page to a 500 halfway through the flow.
      def configured?
        [slug, client_id, client_secret].none? { |value| value == PLACEHOLDER }
      end

      # Where a user goes to install the App and choose repositories. GitHub renders the picker and
      # the consent screen from the App's own configuration; nothing about that page is built here.
      #
      # `state` is GitHub's own round-trip parameter: it is handed back unchanged, which is how a
      # user lands back where they started. It is opaque to GitHub and is validated on the way back,
      # never trusted — see `GithubInstallationsController#create`.
      def installation_url(state: nil)
        url = "#{GITHUB_HOST}/apps/#{ERB::Util.url_encode(slug)}/installations/new"
        state.present? ? "#{url}?#{URI.encode_www_form(state: state)}" : url
      end

      # Where a user goes to hand SpecGuard a fresh user-to-server token WITHOUT being walked
      # through the repository picker again.
      #
      # Reading a user's repositories needs a credential that speaks for that user, and such a
      # credential is deliberately not persisted — it lives in their session and goes when the
      # session does. This is how the next session gets one. For somebody who has already authorized
      # the App, GitHub renders nothing at all: it redirects straight back to the callback with a
      # new `code`, so the whole round trip is invisible apart from the browser's address bar.
      #
      # Distinct from `installation_url` because the two ask for different things. This asks only
      # "are you still you"; that one asks "which repositories may SpecGuard see", which is a
      # decision a user should not be re-prompted for every time their session expires.
      def authorization_url(state: nil)
        query = { client_id: client_id }
        query[:state] = state if state.present?

        "#{GITHUB_HOST}/login/oauth/authorize?#{URI.encode_www_form(query)}"
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
