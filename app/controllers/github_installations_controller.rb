# frozen_string_literal: true

# Connecting repositories: sending a user to GitHub to install the SpecGuard App, and recording
# what they came back with.
#
#   POST /github/installation           → off to GitHub's installation flow
#   GET  /github/installation/callback  → GitHub's Setup URL, where they land afterwards
#
# ## The picker is GitHub's, not ours
#
# `create` does nothing but redirect. Which repositories a user hands over, and the consent screen
# that names what SpecGuard will be able to read, are rendered by GitHub from the App's own
# configuration on github.com. None of that is built here, mirrored here, or asserted from here —
# a copy in this repository could only ever disagree with the authority.
#
# ## The callback trusts the code, never the id
#
# GitHub returns the user carrying `?installation_id=N`, and that is a query string on a GET: anyone
# can type it with a stranger's installation id in it. Recording it unchecked would hand the forger
# every repository in somebody else's installation, which is the squatting gap this slice closes,
# reopened at a wider gauge.
#
# So the id is a claim. What settles it is the `code` GitHub sends alongside — issued to this
# browser, single-use, worthless to anyone who did not just complete the flow — which
# `GithubAppUserAuthorization` exchanges for GitHub's own answer to "which installations does this
# user hold". That answer is what gets recorded, and the `installation_id` parameter is never read.
#
# Every installation GitHub reports is recorded, not only the one just created. A user who
# administers two organizations reaches both in one trip, and asking them to run the flow again per
# organization would be asking them to repeat a journey GitHub has already answered in full.
class GithubInstallationsController < ApplicationController
  # The return path round-trips through GitHub's `state`, so it comes back as user-controlled input.
  include SafeReturnPath

  before_action :require_authentication
  before_action :require_configured_app

  # Off to GitHub. `allow_other_host` is required and is the point: the whole action is a redirect
  # to github.com.
  #
  # POST rather than GET, and CSRF-protected as any other POST, so a third-party page cannot bounce
  # a signed-in user into an installation flow they did not ask for.
  def create
    redirect_to SpecGuard::GithubApp.installation_url(state: return_path_param),
                allow_other_host: true
  end

  # GitHub's Setup URL. Reached after an install, and again after every reconfigure — the flow is
  # idempotent on GitHub's side and is idempotent here (see `GithubInstallation.record`).
  #
  # `require_authentication` guards it, which means somebody who installs the App from GitHub
  # directly rather than from a SpecGuard page — from the App's own listing, say — lands here with
  # no session and is sent to sign in. That is the correct answer rather than a gap: an
  # installation is recorded AGAINST A USER, and there is nobody to record it against. They sign in
  # and press Connect, GitHub sees the App is already installed, runs them straight back through
  # here, and the installation is picked up on that pass.
  #
  # `setup_action` is deliberately not branched on. GitHub sends `install` or `update` and the
  # response to both is identical: ask GitHub what this user holds now, and record that. Reading it
  # would be reading our own guess about what changed instead of GitHub's statement of what is.
  def callback
    installations = GithubAppUserAuthorization.installations(code: params[:code])
    recorded = record(installations)

    redirect_to destination, notice: connected_notice(recorded)
  rescue GithubApi::Error => e
    # Failing closed: nothing is recorded, so a user whose exchange failed is exactly as connected
    # as they were before — which is the only safe reading of "GitHub would not confirm this".
    Rails.logger.warn("[GithubInstallations] callback: #{e.class}: #{e.message}")

    redirect_to destination, alert: connection_failed_alert
  end

  private

  # An unconfigured instance says so instead of bouncing the user to a github.com URL built from
  # placeholders, which would 404 on GitHub and leave them with no idea why. The same absent-
  # credentials shape `SpecGuard::GithubOauth` uses for sign-in.
  def require_configured_app
    return if SpecGuard::GithubApp.configured?

    redirect_to repositories_path, alert: "The SpecGuard GitHub App is not configured on this instance."
  end

  def record(installations)
    installations.filter_map do |installation|
      GithubInstallation.record(user: current_user,
                                installation_id: installation.installation_id,
                                account_login: installation.account_login)
    end
  end

  # Where the user was when they left. Carried out in GitHub's `state` and read back here, so it
  # arrives as user-controlled input and is admitted only as a path on this site.
  def destination = safe_return_path(params[:state], fallback: repositories_path)

  # Read on the way OUT, where it is this app's own `request.referer`-free value rather than
  # anything GitHub has touched — but validated all the same, because it arrives as a form
  # parameter and a form parameter is a form parameter.
  def return_path_param = safe_return_path(params[:return_to], fallback: repositories_path)

  # Names the accounts, because "connected" is not the same sentence when a user expected two
  # organizations and GitHub reported one. An empty result is its own case: GitHub confirmed the
  # authorization and reported no installations, which is what cancelling out of the picker looks
  # like, and telling that user "repositories connected" would be telling them something false.
  def connected_notice(recorded)
    return "GitHub reported no SpecGuard installations for your account yet." if recorded.empty?

    "Connected #{recorded.map(&:display_name).to_sentence}."
  end

  def connection_failed_alert
    "GitHub could not confirm the installation, so nothing was connected. Try connecting again."
  end
end
