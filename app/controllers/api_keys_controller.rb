# frozen_string_literal: true

class ApiKeysController < ApplicationController
  before_action :require_authentication

  # Reveal-once: the raw token is put in the flash for exactly the redirect that follows, and is
  # never persisted anywhere. Only the SHA-256 digest reaches the database.
  def create
    repository = current_repository(:keys_manage)
    api_key = repository.api_keys.create!(name: api_key_name, created_by_user: current_user)

    reveal(api_key)
    redirect_to repository_path(repository), notice: "API key created. Copy it now — it is shown only once."
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
    redirect_to repository_path(repository),
                notice: "API key regenerated. The previous token has stopped working — copy the new one now, " \
                        "it is shown only once."
  end

  def destroy
    repository = current_repository(:keys_manage)
    repository.api_keys.find(params[:id]).destroy!

    redirect_to repository_path(repository), notice: "API key revoked."
  end

  private

  # Read once, by `RepositoriesController#show`, on the redirect that follows.
  def reveal(api_key)
    flash[:revealed_api_key] = api_key.raw_token
    # Deliberately a *second* flash value: `revealed_api_key` has to stay a bare token, because the
    # copy-text Stimulus controller copies that element's text verbatim.
    flash[:revealed_api_key_name] = api_key.name
  end

  def api_key_name
    params.dig(:api_key, :name).presence || "Default CI Key"
  end
end
