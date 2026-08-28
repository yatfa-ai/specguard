# frozen_string_literal: true

class ApiKeysController < ApplicationController
  before_action :require_authentication

  # Where both reveal paths redirect: the id of the panel `repositories/_revealed_token` renders.
  #
  # A fragment rather than nothing, because a correct render is not enough. `repositories#show` is a
  # tall template and both controls that reach this class — the mint form and each row's rotate
  # button — sit near the bottom of it, while the reveal renders near the top. Landing on the page
  # with the previous scroll position intact means the person who pressed the button sees nothing
  # happen, and the value is shown exactly once.
  #
  # It is one of two mechanisms and covers the ones the other cannot: a browser with JavaScript off,
  # and Turbo's own anchor handling on an ordinary advance visit.
  # `scroll_into_view_controller.js` covers the case where Turbo restores the prior scroll instead.
  REVEAL_ANCHOR = "revealed-key"

  # Reveal-once: the raw token is put in the flash for exactly the redirect that follows, and is
  # never persisted anywhere. Only the SHA-256 digest reaches the database.
  def create
    repository = current_repository(:keys_manage)
    api_key = repository.api_keys.create!(name: api_key_name, created_by_user: current_user)

    reveal(api_key)
    redirect_to reveal_path(repository), notice: "API key created. Copy it now — it is shown only once."
  end

  # The recovery path for a key whose plaintext is gone: mint a new token onto the same row. There
  # is no way to re-show the old one — `ApiKey` keeps a digest and nothing else — so the only
  # honest answer to "I lost my key" is to replace it.
  #
  # This travels the same reveal-once flash as `create`, deliberately: a regenerated token is
  # exactly as unrecoverable as a freshly minted one, and a second reveal path would be a second
  # chance to get that wrong. Gated at `:keys_manage`, matching `create` and `destroy` — rotating a
  # key is bounded above by minting one, since the holder of that permission can already replace
  # any key with a create plus a revoke.
  def regenerate
    repository = current_repository(:keys_manage)
    api_key = repository.api_keys.find(params[:id])
    api_key.regenerate!

    reveal(api_key)
    # Not folded into `reveal`: it is what distinguishes the two callers, and it is read to decide
    # whether the panel warns that something just stopped working.
    flash[:revealed_api_key_regenerated] = true
    redirect_to reveal_path(repository),
                notice: "API key regenerated. The previous token has stopped working — copy the new one now, " \
                        "it is shown only once."
  end

  def destroy
    repository = current_repository(:keys_manage)
    repository.api_keys.find(params[:id]).destroy!

    redirect_to repository_path(repository), notice: "API key revoked."
  end

  private

  # The repository page, anchored on the reveal panel. Shared by both reveal paths rather than
  # written twice, on the same rule `reveal` itself follows: mint and rotate are one flow wearing
  # two verbs, and the one that is only correct on one of them is the bug this ticket fixed.
  #
  # `#destroy` deliberately does NOT use it — revoking a key reveals nothing, so there is no panel
  # to land on and the fragment would point at an element that is not rendered.
  def reveal_path(repository) = repository_path(repository, anchor: REVEAL_ANCHOR)

  # Read once, by `RepositoriesController#show`, on the redirect that follows.
  def reveal(api_key)
    flash[:revealed_api_key] = api_key.raw_token
    # Deliberately a *second* flash value: `revealed_api_key` has to stay a bare token, because the
    # copy-text Stimulus controller copies that element's text verbatim.
    flash[:revealed_api_key_name] = api_key.name
  end

  # The name a key gets when the mint form's name field was left blank. Reads `ApiKey::DEFAULT_NAME`
  # rather than repeating the literal: three paths now mint an unnamed key — this form, an agent
  # registering over the API, and a browser registering a whole organization — and
  # `Api::V1::UserRepositoriesController::FIRST_KEY_NAME` states why they must not drift apart.
  def api_key_name
    params.dig(:api_key, :name).presence || ApiKey::DEFAULT_NAME
  end
end
