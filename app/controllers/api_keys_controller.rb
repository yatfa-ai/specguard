# frozen_string_literal: true

class ApiKeysController < ApplicationController
  before_action :require_authentication

  # Reveal-once: the raw token is put in the flash for exactly the redirect that follows, and is
  # never persisted anywhere. Only the SHA-256 digest reaches the database.
  def create
    repository = current_repository(:keys_manage)
    api_key = repository.api_keys.create!(name: api_key_name, created_by_user: current_user)

    flash[:revealed_api_key] = api_key.raw_token
    # Deliberately a *second* flash value: `revealed_api_key` has to stay a bare token, because the
    # copy-text Stimulus controller copies that element's text verbatim.
    flash[:revealed_api_key_name] = api_key.name
    redirect_to repository_path(repository), notice: "API key created. Copy it now — it is shown only once."
  end

  def destroy
    repository = current_repository(:keys_manage)
    repository.api_keys.find(params[:id]).destroy!

    redirect_to repository_path(repository), notice: "API key revoked."
  end

  private

  def api_key_name
    params.dig(:api_key, :name).presence || "Default CI Key"
  end
end
