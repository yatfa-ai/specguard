# frozen_string_literal: true

# MINTING, REVOKING, AND (SPGD-993) LISTING A REPOSITORY'S OWN `sgk_` KEYS, over a `sgu_` user
# key (SPGD-754) — the mutating half of the key surface the web `ApiKeysController` has always
# served in a browser, plus the inventory read that makes its recovery story completable —
# and, since SPGD-973, all of it over an `sga_` agent key holding `keys.manage` on the repository.
#
# ## Why this is not `ApiKeysController`
#
# That class is an `ApplicationController`: it renders HTML, reads a session, and reveals a minted
# token in a FLASH through a redirect. This one renders JSON to a principal named by a token, with
# no session anywhere near it. The two share one thing, deliberately and structurally: the
# authorization. Both call `current_repository(:keys_manage)` — the concern both bases include —
# so who may mint, list, or revoke a key is one rule, and a change to it cannot land on one
# surface and miss the other. SPGD-973 is what makes that sharing total: the gate is a capability
# question, and an agent credential answers capability questions through `AgentApiKeyPolicy` like
# any other, bounded by its own set and permissions — no second gate to drift.
#
# ## What is deliberately NOT here
#
# `#regenerate`. The roadmap rules in-place rotation out of the API surface, and `ApiKey#regenerate!`'s
# own comment records the reason: a regenerated token stops the old one working with no grace
# window, and a CI pipeline holding the old token fails its next push. A caller who lost a token
# has the same recovery over the API as in a browser — mint a replacement, revoke the orphan —
# and since SPGD-993 that story is actually completable over the API: `#index` below serves each
# row's `id`, which is the one fact `#destroy` requires and the one fact the mint responses could
# not name, because the token is reveal-once and the id was never served before the inventory
# existed.
#
# ## Reveal-once is not re-invented here
#
# `Api::V1::UserRepositoriesController#create` set the precedent this follows to the field: the
# mint response carries `token: api_key.raw_token` — the only time the value exists anywhere —
# alongside the same `name`/`hint`/`created_at` block, and `created_by_user` records who the
# write is attributed to, exactly as `ApiKeysController#create` attributes the browser's mint.
# For an agent credential that is the KEY'S OWNER (`Api::BaseController#attributed_user`), so
# the row's `MembershipsController#keys_minted_by` attribution names a person rather than
# reading "Unknown" — the known-degraded state a nil creator renders. No later endpoint serves
# the token; nothing persists it but the digest.
class Api::V1::UserRepositoryApiKeysController < Api::BaseController
  # WHO MAY MINT, LIST, AND REVOKE: a person over their `sgu_` key, or an `sga_` agent credential
  # holding `keys.manage` on a repository in its own set — both answered by the same
  # `current_repository(:keys_manage)` gate each action already calls. A repository's own `sgk_`
  # key speaks for the repository, not for anybody who may administer its keys, and gets 401
  # here — see `Api::BaseController`.
  accepts_user_credential
  accepts_agent_credential

  # THE INVENTORY (SPGD-993) — the read that makes the mint-and-replace rotation above
  # completable over the API alone. The mint response reveals its token once and never again,
  # and `#destroy` names rows by primary key, so before this action existed a caller who lost a
  # token could mint the replacement but could never identify the orphan to revoke — the
  # browser's key table (`repositories/_api_keys`) is session- and CSRF-gated, closed to a
  # token-holder by construction.
  #
  # Every row of the repository's own keys, live AND revoked — the same population
  # `GET /api/v1/repositories/:id`'s `credential_health` already discloses to this very viewer
  # by name and timestamps. This adds the `id` that makes that disclosure actionable; it opens
  # no new class of disclosure, because the same `keys.manage` gate answers before any row is
  # read. The token itself is never served — see `#serialize`.
  #
  # `includes(:created_by_user)` for the same N+1 reason the members `#index` states: every row
  # reads one `users` column, and an unloaded association would cost a query per row. `order(:id)`
  # keeps the response stable between calls in insertion order.
  def index
    repository = current_repository(:keys_manage)
    keys = repository.api_keys.includes(:created_by_user).order(:id)

    render json: { api_keys: keys.map { |api_key| serialize(api_key) } }
  end

  # MINT A SUBSEQUENT KEY — the act the first key got bundled with registration because a
  # repository with no key is a repository nothing can deliver to. This one is for every key
  # after that: rotation by replacement, a second pipeline, a key per environment.
  #
  # The name is optional and defaults to the same constant the other three minting paths read
  # (`ApiKeysController`, `UserRepositoriesController#create`, `BulkRegistration`), so a key minted
  # by an agent and one minted in a browser are named by one rule rather than two conventions.
  def create
    repository = current_repository(:keys_manage)
    api_key = repository.api_keys.create!(name: key_name, created_by_user: attributed_user)

    render json: minted_body(api_key), status: :created
  end

  # REVOKE ONE — within the repository's own keys, so an id from a DIFFERENT repository is a 404
  # rather than a cross-repository delete: `repository.api_keys.find` scopes the lookup, and the
  # `RecordNotFound` it raises is caught by `Api::BaseController` and rendered as this API's own
  # JSON, not Rails' public-exception page.
  #
  # A RETIREMENT, matching the web action (`ApiKeysController#destroy`, SPGD-804): `revoke!` stamps
  # `revoked_at` and the row stays, so a revoked token stays attributable — a pipeline still
  # presenting it is reportable by `credential_health` instead of reading "Not connected yet".
  # Sharing one rule is the point of this controller: the two surfaces deliberately authorize the
  # gesture identically, and a caller revoking over the API must get the same semantics as one
  # clicking Revoke in a browser — including the observability the retained row buys.
  #
  # Revoking one key leaves the repository's others authenticating — that asymmetry is the whole
  # reason a caller mints a replacement before revoking, and the spec pins it.
  def destroy
    repository = current_repository(:keys_manage)

    repository.api_keys.find(params[:id]).revoke!

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
  # `id` rides both blocks (SPGD-993): the token is reveal-once, so the id is the caller's only
  # durable handle on the row this response just created — the exact handle `#destroy` and
  # `#index` name rows by.
  def minted_body(api_key)
    {
      api_key: {
        id: api_key.id,
        name: api_key.name,
        # ⚠️ THE ONLY TIME THIS VALUE EXISTS ANYWHERE. Nothing stores it and no endpoint can
        # re-serve it; a caller that loses it mints a replacement.
        token: api_key.raw_token,
        hint: api_key.token_hint,
        created_at: api_key.created_at.iso8601
      }
    }
  end

  # One inventory row. `token_hint` — never the token: digest-only storage stands, and the class
  # header's "no later endpoint serves the token" sentence stays true by construction here, since
  # the only plaintext this row could name was never persisted. `created_by` renders the same
  # degraded "Unknown" the web key table renders for a key minted before attribution existed or
  # whose creator is gone (`User#display_name`, so it reads what the page reads). `status` is the
  # model's own retirement split (`live`/`revoked` scopes) spelled out per row, with `revoked_at`
  # served only when the row carries one — a live key's "revoked_at: null" would restate the
  # status field, and the two-writings-one-fact shape is what lets them drift.
  def serialize(api_key)
    row = {
      id: api_key.id,
      name: api_key.name,
      token_hint: api_key.token_hint,
      created_at: api_key.created_at.iso8601,
      created_by: api_key.created_by_user&.display_name || "Unknown",
      last_used_at: api_key.last_used_at&.iso8601,
      status: api_key.revoked_at ? "revoked" : "live"
    }
    row[:revoked_at] = api_key.revoked_at.iso8601 if api_key.revoked_at
    row
  end
end
