# frozen_string_literal: true

# The person's own page: what belongs to them rather than to any one repository.
#
# Today that is exactly one thing — their `sgu_` user API keys — and the page is deliberately not
# named for them. An account surface is where a profile, a notification setting or a sign-out-
# everywhere control would land, and naming the route after its first occupant would make each of
# those a second top-level page.
class AccountsController < ApplicationController
  before_action :require_authentication

  def show
    # Newest first: the key somebody just minted is the one they came back to check, and the reveal
    # panel above the table is about that same row. Tie-broken by id so two keys minted in the same
    # instant — which a person clicking twice can produce — still order deterministically, the same
    # rule `Repository#latest_test_run` follows.
    @user_api_keys = current_user.user_api_keys.order(created_at: :desc, id: :desc)

    # Set by UserApiKeysController#create, readable exactly once — the SAME flash keys
    # `ApiKeysController` writes and `RepositoriesController#show` reads. One reveal-once mechanism
    # for both credentials, not two: a second implementation is a second chance to get "shown
    # exactly once" wrong, and the two pages can never be reached by one redirect.
    @revealed_token = flash[:revealed_api_key]
    @revealed_token_name = flash[:revealed_api_key_name]

    # REGISTRATION ACCESS, which is the one credential on this page that EXPIRES and the only one
    # whose age was reported nowhere. The keys above are revoked or they work; a
    # `GithubRegistrationGrant` lapses after `GithubRegistrationGrant::MAX_AGE` on its own, and
    # nothing looks broken when it does — `GET /api/v1/repositories` needs no grant and keeps
    # answering, and `last_used_at` keeps updating. A person who mints a key, hands it to an agent
    # and does not open SpecGuard in a browser for a week loses the ability to register with no
    # sign of it anywhere. This page is where that had to become visible, beside the credential it
    # is a property of.
    #
    # Through the `has_one` association rather than a `find_by`, matching what
    # `Api::V1::UserRepositoriesController#grant_verifier` reads: "one grant per person" is a fact
    # of the schema (unique index on `user_id`) rather than a convention each caller re-states.
    #
    # `nil` is an ORDINARY state — every person who has not listed repositories in a browser since
    # the grant mechanism shipped — and the view says so rather than treating it as an error.
    #
    # ⚠️ This is a READ. It must never become a `GithubRegistrationGrant.capture`: the sole capture
    # site is `GithubRepositoryListing#github_sources`, deliberately, because that is a GitHub read
    # the browser was making anyway. Refreshing from here would add a page-walk per installation to
    # a page that lists no repositories.
    @registration_grant = current_user.github_registration_grant

    # CONNECTED GITHUB ACCOUNTS — the rows `GithubInstallationsController#callback` writes, which
    # until now appeared on no page at all and could be removed by nothing short of deleting the
    # whole user. `User#github_installations` says the principle outright while justifying its
    # `dependent: :destroy`: connecting GitHub is not the sort of act that should quietly become
    # irreversible. The cascade was the only satisfier funded; this list and its Disconnect are the
    # other half.
    #
    # `recent_first` rather than a fresh `order` here — its own comment already names this list as
    # the reason it exists, so the ordering rule lives with the model instead of being restated at
    # the one call site that could drift from it.
    #
    # ⚠️ A READ, on the same terms as the grant above and for a sharper reason: these rows are not
    # synced with GitHub (see `GithubInstallation`), and the honest way to show what is really there
    # would be a live page-walk per installation. That is the cost `/repositories/new` already pays
    # and this page deliberately does not — listing SpecGuard's own record is what the panel claims
    # to show, and it is what the Disconnect acts on.
    @github_installations = current_user.github_installations.recent_first
  end
end
