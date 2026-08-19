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
  end
end
