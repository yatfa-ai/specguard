# frozen_string_literal: true

# MINTING AND REVOKING A REPOSITORY'S OWN `sgk_` KEYS, over a `sgu_` user key (SPGD-754) — the
# mutating half of the key surface the web `ApiKeysController` has always served in a browser.
#
# ## Why this is not `ApiKeysController`
#
# That class is an `ApplicationController`: it renders HTML, reads a session, and reveals a minted
# token in a FLASH through a redirect. This one renders JSON to a person named by a token, with no
# session anywhere near it. The two share one thing, deliberately and structurally: the
# authorization. Both call `current_repository(:keys_manage)` — the concern both bases include —
# so who may mint or revoke a key is one rule, and a change to it cannot land on one surface and
# miss the other.
#
# ## What is deliberately NOT here
#
# `#regenerate`. The roadmap rules in-place rotation out of the API surface, and `ApiKey#regenerate!`'s
# own comment records the reason: a regenerated token stops the old one working with no grace
# window, and a CI pipeline holding the old token fails its next push. A caller who lost a token
# has the same recovery over the API as in a browser — mint a replacement, revoke the orphan.
#
# ## Reveal-once is not re-invented here
#
# `Api::V1::UserRepositoriesController#create` set the precedent this follows to the field: the
# mint response carries `token: api_key.raw_token` — the only time the value exists anywhere —
# alongside the same `name`/`hint`/`created_at` block, and `created_by_user` records the person
# whose token minted it, exactly as `ApiKeysController#create` attributes the browser's mint. No
# later endpoint serves the token; nothing persists it but the digest.
class Api::V1::UserRepositoryApiKeysController < Api::BaseController
  # THIS ENDPOINT NEEDS A PERSON. A repository's own `sgk_` key speaks for the repository, not for
  # anybody who may administer its keys, and gets 401 here — see `Api::BaseController`.
  accepts_user_credential

  # MINT A SUBSEQUENT KEY — the act the first key got bundled with registration because a
  # repository with no key is a repository nothing can deliver to. This one is for every key
  # after that: rotation by replacement, a second pipeline, a key per environment.
  #
  # The name is optional and defaults to the same constant the other three minting paths read
  # (`ApiKeysController`, `UserRepositoriesController#create`, `BulkRegistration`), so a key minted
  # by an agent and one minted in a browser are named by one rule rather than two conventions.
  def create
    repository = current_repository(:keys_manage)
    api_key = repository.api_keys.create!(name: key_name, created_by_user: current_api_user)

    render json: minted_body(api_key), status: :created
  end

  # REVOKE ONE — within the repository's own keys, so an id from a DIFFERENT repository is a 404
  # rather than a cross-repository delete: `repository.api_keys.find` scopes the lookup, and the
  # `RecordNotFound` it raises is caught by `Api::BaseController` and rendered as this API's own
  # JSON, not Rails' public-exception page.
  #
  # `destroy!` rather than `destroy`: the row is in hand and unlocked, so a failed destroy is a
  # fault to raise on, not a state to answer 200 for. The web action uses the same call.
  #
  # Revoking one key leaves the repository's others authenticating — that asymmetry is the whole
  # reason a caller mints a replacement before revoking, and the spec pins it.
  def destroy
    repository = current_repository(:keys_manage)

    repository.api_keys.find(params[:id]).destroy!

    head :no_content
  end

  private

  # The same read the web mint form makes: a blank name is a valid state and gets the default, not
  # an error. Top-level `params[:name]` rather than a nested `api_key` block, matching
  # `UserRepositoriesController#create_params`'s stated rule — this is JSON an agent writes by
  # hand, not a Rails form.
  def key_name
    params[:name].presence || ApiKey::DEFAULT_NAME
  end

  # Deliberately the same `api_key` block `UserRepositoriesController#registered_body` serves, so
  # a client that has read one mint response knows how to read the other — the rule that
  # controller's `#serialize` states for the `repository` block, applied to its own sibling.
  def minted_body(api_key)
    {
      api_key: {
        name: api_key.name,
        # ⚠️ THE ONLY TIME THIS VALUE EXISTS ANYWHERE. Nothing stores it and no endpoint can
        # re-serve it; a caller that loses it mints a replacement.
        token: api_key.raw_token,
        hint: api_key.token_hint,
        created_at: api_key.created_at.iso8601
      }
    }
  end
end
