# frozen_string_literal: true

# THE REPOSITORY'S AGENT-KEY INVENTORY AND ITS REVOKE, OVER THE API (SPGD-1004) — the API half
# SPGD-989 scoped out and SPGD-993 fenced to this lane. SPGD-989 shipped both halves of this
# surface browser-only: the listing renders inside `repositories#show`
# (`repositories/_agent_keys`, session + CSRF, closed to a token-holder by construction) and the
# revoker is `RepositoryAgentKeysController`, a web controller. SPGD-993 then gave the `sgk_`
# sibling this exact pair over the API while its out-of-scope section fenced THIS noun off as
# deferred. The asymmetry had a casualty: a `keys.manage` holder operating over the token
# surface — the `sga_` automation principal SPGD-973 created, an `sgu_` key in a script, any
# person without a browser session — could mint and revoke `sgk_` keys but could never see or
# retire the `sga_` keys covering a repository, so the offboarding arc SPGD-989 exists to close
# (a departed member's agent key authenticating indefinitely, revocable only by its owner) was
# not completable by the principal built for automation. This controller closes it.
#
# ## Why the authorization is not new
#
# Both actions call the SAME `current_repository(:keys_manage)` gate the web listing renders
# behind, the web revoker authorizes with, and the `sgk_` API pair answers to —
# `RepositoryAuthorization` is the one place the rule lives, and nothing here re-spells it. The
# declarations below are the credential seam only: a person over their `sgu_` key, or an `sga_`
# agent credential whose own set and permission set bound every action it reaches (a repository
# outside the key's stored set is a 404 before any capability is asked; a repository's own
# `sgk_` key is refused 401 at the credential layer, as on every person/agent endpoint).
#
# ## What is deliberately NOT here
#
# Minting. An agent key's grant — a repository set and a permission set — is chosen once, at
# /account, from the minter's own rights (`AgentApiKey`'s validations); the web resource's route
# comment states the same rule for the web face. No `regenerate!` either — the model has none,
# deliberately: a lost agent token is recovered by minting another and revoking this one, and as
# of this controller that arc finally works over the API alone for the third credential kind,
# exactly as SPGD-993 made it work for the second. The inventory's row shape is web-panel
# parity; the one deliberate extension beyond it is `presented_revoked` (SPGD-1023) — the
# verify half this header's own fence anticipated as "a follow-up if the API wants it", and
# the API does: the still-presented triage reads the retained revoked rows `last_refused_at`
# is stamped on, which no live-only listing could serve.
class Api::V1::UserRepositoryAgentKeysController < Api::BaseController
  # WHO MAY LIST AND REVOKE: a person over their `sgu_` key, or an `sga_` agent credential
  # holding `keys.manage` on a repository in its own set — both answered by the same
  # `current_repository(:keys_manage)` gate each action calls. A repository's own `sgk_` key
  # speaks for the repository, not for anybody who may administer its keys, and gets 401
  # here — see `Api::BaseController`.
  accepts_user_credential
  accepts_agent_credential

  # THE INVENTORY — the read that makes the offboarding arc completable by a token-holder. The
  # web panel hands its partial only LIVE rows (SPGD-804's rule, carried on this table: a
  # revoked row is retained but is not a credential, so it leaves the listing rather than
  # changing its badge) and so does this action: `live` first, then `covering` for the
  # boundary — exactly the rows whose stored set names this repository.
  #
  # `eager_load(:user)` is the join `covering`'s table qualification was written for and the
  # web listing pays, so the owner cell costs nothing per row and the whole listing is ONE
  # statement against `agent_api_keys`. `order(:id)` keeps the response stable between calls,
  # the same spelling the `sgk_` inventory uses.
  def index
    repository = current_repository(:keys_manage)
    keys = AgentApiKey.live.covering(repository).eager_load(:user).order(:id)

    render json: { agent_keys: keys.map { |agent_api_key| serialize(agent_api_key) } }
  end

  # REVOKE ONE — `RepositoryAgentKeysController#destroy` carried over a Bearer token, line for
  # line where it matters: `current_repository(:keys_manage)` authorizes, `AgentApiKey.live.find`
  # refuses a replayed revoke on the usual 404 (a revoked row is retained but is not a
  # credential), and the `covers?` guard binds the KEY to THIS repository — a `keys.manage`
  # holder of repo A cannot revoke a key whose stored set excludes A. Out-of-boundary answers
  # 404, the same nil-is-404 fork every repository read takes: the refusal says nothing about a
  # key the caller has no business knowing exists.
  #
  # THE BODY IS THE POINT. On the web, the confirm dialog names the key's FULL stored set
  # (count + names) BEFORE the cut, and `agent_key_revoke_notice` renders the same disclosure
  # after it — one-act honesty. Over the API there is no confirm dialog, so the disclosure
  # travels in the response that performs the cut: `revoke!` on a multi-repository key cuts the
  # token EVERYWHERE (the set is one grant, stored once), and the caller must learn the blast
  # radius in the same breath as the act. The gate stays `keys.manage` over THIS repository —
  # the disclosure, not a wider gate, is the mechanism. 200 rather than the sibling's 204
  # because the body is the point: a 204 carries none.
  def destroy
    repository = current_repository(:keys_manage)
    agent_api_key = AgentApiKey.live.find(params[:id])
    raise ActiveRecord::RecordNotFound unless agent_api_key.covers?(repository)

    agent_api_key.revoke!
    render json: revoked_body(agent_api_key)
  end

  # THE VERIFY HALF OF THE OFFBOARDING ARC (SPGD-1023) — the still-presented triage over the
  # API. `#index` and `#destroy` are the write half of the arc: they answer "what is live"
  # and "cut this one". Neither can answer the question a revoker is left with after the cut —
  # "is the dead token still arriving?" — because both read LIVE rows only, and the stamp
  # could not ride a live row anyway: `last_refused_at` is stamped by the 401 failure path
  # (`Api::BaseController#attribute_refused_revocation`) on RETAINED revoked rows, and the
  # model pins live-with-stamp as structurally unreachable. The evidence has been written
  # since SPGD-991; this action is the API surface that serves it, behind the same
  # `current_repository(:keys_manage)` gate the other two actions answer to — the revoker is
  # the one role that needs to know whether offboarding actually took, and in the offboarding
  # arc (a departed member's key) is precisely NOT the key's owner, so /account cannot answer
  # them.
  #
  # The read mirrors `RepositoryOverview#serialized_credential_health`'s construction for the
  # `sgk_` sibling, including the seam the split is read through: the retained rows a `WHERE`
  # would have filtered out are loaded ONCE — `revoked.covering(repository).eager_load(:user)`,
  # every row REVOKED, so the partition's stranded half (a rotation question AgentApiKey has no
  # concept of) is never reached — and the presented side comes from `ApiKeyPartition`, the one
  # place the collection split is spelled (`spec/models/api_key_partition_spec.rb` holds that
  # repo-wide property). Filtering these rows by hand here would be a second spelling of the
  # split, free to drift from the one /account reads, and this block exists to stop the API and
  # /account disagreeing about a key.
  #
  # THE NEGATIVE IS SERVED, NOT OMITTED — the sibling block's standing rule: an empty result
  # renders `{"agent_keys": []}` with 200, so "no revoked key is still being presented" is an
  # ANSWER, distinguishable from "the API does not track that". The honesty clause travels
  # with the row: `last_refused_at` is the LAST observed presentation — a recency, never a
  # present-tense claim about a client presenting it now. Name, hint and blast radius travel
  # so the remedy (update whichever secret store still holds it) is actionable; the token
  # itself never does — the plaintext existed for exactly one response at mint time and
  # nothing persisted it.
  def presented_revoked
    repository = current_repository(:keys_manage)
    partition = ApiKeyPartition.for(AgentApiKey.revoked.covering(repository)
                                                  .eager_load(:user).order(:id))

    render json: {
      agent_keys: partition.presented_revoked_rows.map do |agent_api_key|
        serialize_presented_revoked(agent_api_key)
      end
    }
  end

  private

  # One inventory row — the web panel's row, served as JSON: name, owner, hint, the stored
  # set's size (the glanceable half of the blast-radius fact the panel shows as a number), the
  # permission set rendered the way the panel renders it ("read only" for the minimal grant the
  # model explicitly allows), and the creation timestamp. `token_hint` — never the token: the
  # plaintext existed for exactly one response at mint time and nothing persisted it.
  #
  # `owner` is null-safe the way the panel's cell is (`user&.display_name || "Unknown"`);
  # `user_id` is NOT NULL, so the fork exists for a dangling id — a defensive rendering, not a
  # state the application writes. With `#index`'s `eager_load(:user)` every read here is off
  # the one loaded join: no query per row.
  def serialize(agent_api_key)
    {
      id: agent_api_key.id,
      name: agent_api_key.name,
      owner: agent_api_key.user&.display_name || "Unknown",
      token_hint: agent_api_key.token_hint,
      repository_count: agent_api_key.repository_ids.size,
      permissions: agent_api_key.permissions.any? ? agent_api_key.permissions.join(", ") : "read only",
      created_at: agent_api_key.created_at.iso8601
    }
  end

  # The one-act disclosure, count first then names — the same reading and the same ORDER as
  # `RepositoriesHelper#agent_key_coverage_sentence`, the one place the web decides this copy.
  # The count is the STORED set's size (the blast radius, read off the array the grant froze at
  # mint time); the names are the set's still-existing repositories, sorted the way the notice
  # sorts them. Repositories deleted since mint drop out of the names on their own, and the
  # difference is DISCLOSED rather than left to quietly disagree — `deleted_repository_count`,
  # present only when positive, the coverage sentence's own "(N repositories since deleted)"
  # parenthetical. A `0` field would restate `repository_count - repositories.size`, the
  # two-writings-one-fact shape the sibling serializer's `revoked_at` note refuses.
  def revoked_body(agent_api_key)
    names = agent_api_key.repositories.order(:github_full_name).pluck(:github_full_name)
    body = {
      agent_key: {
        id: agent_api_key.id,
        name: agent_api_key.name,
        revoked_at: agent_api_key.revoked_at.iso8601,
        repository_count: agent_api_key.repository_ids.size,
        repositories: names
      }
    }
    deleted = agent_api_key.repository_ids.size - names.size
    body[:agent_key][:deleted_repository_count] = deleted if deleted.positive?
    body
  end

  # One presented-revoked triage row — the remedy story, seven fields exactly: who held it
  # (`owner`, null-safe the way the panel's cell is — "Unknown" for a dangling id, a defensive
  # rendering, not a state the application writes), which hint to hunt for in the secret store
  # (`token_hint`, NEVER the token), how wide the blast radius is (`repository_count`, the
  # STORED set's size — read off the array the grant froze at mint time, the same figure the
  # revoke response discloses), when it died (`revoked_at`) and when it was last seen arriving
  # (`last_refused_at`). Both stamps are present by construction of the partition side the
  # action serves, so neither renders with a `&.` — the sibling block's own spelling. With
  # the action's `eager_load(:user)` every read here is off the one loaded join: no query per
  # row, and the whole response is ONE statement against `agent_api_keys`.
  def serialize_presented_revoked(agent_api_key)
    {
      id: agent_api_key.id,
      name: agent_api_key.name,
      owner: agent_api_key.user&.display_name || "Unknown",
      token_hint: agent_api_key.token_hint,
      repository_count: agent_api_key.repository_ids.size,
      revoked_at: agent_api_key.revoked_at.iso8601,
      last_refused_at: agent_api_key.last_refused_at.iso8601
    }
  end
end
