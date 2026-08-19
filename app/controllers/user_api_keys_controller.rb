# frozen_string_literal: true

# Minting and revoking the person's own `sgu_` credentials.
#
# ## Authorization is the association, and that is the whole of it
#
# Every read and write goes through `current_user.user_api_keys`, so there is no id a signed-in
# person can type that reaches somebody else's key — `find` on that relation raises
# `RecordNotFound` for a foreign id rather than authorizing it. There is deliberately no
# `RepositoryPolicy` here: these keys hang off a person, and the only question a policy could ask
# is the one the association has already answered.
#
# ## No `regenerate`
#
# Its sibling `ApiKeysController` offers one, because a repository key is usually wired into a CI
# pipeline that would have to be re-pointed. A user key has no such fixture, and the honest answer
# to a lost one is a fresh key plus a revoke — two rows and an audit trail, rather than one row
# whose history quietly changes meaning. `UserApiKey` has no `regenerate!` to call.
class UserApiKeysController < ApplicationController
  before_action :require_authentication

  # The id of the panel `accounts/_revealed_user_token` renders — the fragment the redirect lands
  # on, so the reveal is on screen rather than above the fold somebody has scrolled past. Same
  # mechanism, same reasoning as `ApiKeysController::REVEAL_ANCHOR`.
  REVEAL_ANCHOR = "revealed-key"

  # Reveal-once: the raw token rides the flash for exactly the redirect that follows, and is never
  # persisted anywhere. Only the SHA-256 digest reaches the database.
  def create
    user_api_key = current_user.user_api_keys.create!(name: user_api_key_name)

    # The same two flash keys `ApiKeysController#reveal` writes, deliberately — see
    # `AccountsController#show`. `revealed_api_key` stays a BARE token because the copy-text
    # Stimulus controller copies that element's text verbatim, which is why the name travels
    # separately.
    #
    # The consequence of SHARING those keys with the repository surface, written down rather than
    # discovered later: a flash is consumed by whatever request arrives NEXT, not specifically by
    # the redirect target. If anything intervenes — a Turbo hover-prefetch, a second tab — this
    # `sgu_` token can be consumed by `repositories#show` and rendered in a panel that describes it
    # as that repository's CI key, beside a curl pointed at an endpoint it will 401 against. That
    # is a MISLABELLING risk and not a leak: the only person who can see it is the one who just
    # minted it. It is inherited from the existing mechanism rather than introduced here, and the
    # ticket asked for that mechanism specifically. If a later slice gives the two panels distinct
    # flash keys, this is the reason.
    flash[:revealed_api_key] = user_api_key.raw_token
    flash[:revealed_api_key_name] = user_api_key.name

    redirect_to account_path(anchor: REVEAL_ANCHOR),
                notice: "API key created. Copy it now — it is shown only once."
  end

  # Revokes ONE key. Every other key this person holds keeps working: resolution is a lookup of one
  # digest on a unique index, so the rows know nothing about each other.
  def destroy
    current_user.user_api_keys.find(params[:id]).destroy!

    redirect_to account_path, notice: "API key revoked."
  end

  private

  # A default rather than a validation failure, matching `ApiKeysController#api_key_name`. The name
  # exists to tell several keys apart on the revoke button, and refusing the form over a blank field
  # would be a worse answer than naming it after where it will be pasted.
  def user_api_key_name
    params.dig(:user_api_key, :name).presence || "Personal key"
  end
end
