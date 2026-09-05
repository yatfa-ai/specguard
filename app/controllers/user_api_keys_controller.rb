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

    # This surface's OWN pair of flash keys — deliberately NAMED APART from the pair
    # `ApiKeysController#reveal` writes, while staying one mechanism (see `AccountsController#show`).
    # Two mailboxes, one postal service: a flash is delivered to whatever request arrives NEXT,
    # and while the two surfaces shared one namespace, an intervening `repositories#show` read this
    # surface's mint off the flash and rendered a fresh `sgu_` token in a panel that labelled it
    # that repository's CI key, beside curls it would 401 against. Distinct names confine each
    # surface's reveal to its own reader. What they cannot confine is the transport itself: an
    # intervening request still consumes the flash and leaves the token rendering nowhere (revoke
    # and re-mint) — the reveal-once mechanism's own cost, unchanged here. `revealed_user_api_key`
    # stays a BARE token because the copy-text Stimulus controller copies that element's text
    # verbatim, which is why the name travels separately.
    flash[:revealed_user_api_key] = user_api_key.raw_token
    flash[:revealed_user_api_key_name] = user_api_key.name

    redirect_to account_path(anchor: REVEAL_ANCHOR),
                notice: "API key created. Copy it now — it is shown only once."
  end

  # Retires ONE key. Every other key this person holds keeps working: resolution is a lookup of one
  # digest on a unique index, so the rows know nothing about each other.
  #
  # `revoke!`, not `destroy!` (SPGD-943): the row stays, stamped `revoked_at`. The header above
  # promises that the honest answer to a lost key is "a fresh key plus a revoke — two rows and an
  # audit trail", and a hard delete leaves one row and no trail. Retention is also what makes a
  # revoked token attributable: the dead token arriving at the API stamps `last_refused_at` on the
  # row it names (`Api::BaseController`'s failure path), so /account can say a key you revoked is
  # still being presented rather than leaving the 401 an agent sees indistinguishable from "this
  # was never a key". The button is rendered only on live keys, so a replayed delete re-stamps
  # unobservably — the same idempotence `ApiKey#revoke!` states. Notice and redirect are unchanged:
  # the person asked for the key to stop working, and it has.
  def destroy
    current_user.user_api_keys.find(params[:id]).revoke!

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
