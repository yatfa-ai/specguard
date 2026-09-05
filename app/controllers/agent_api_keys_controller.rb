# frozen_string_literal: true

# Minting and revoking the person's own `sga_` agent credentials (SPGD-952) — the third credential
# kind on `/account`, beside `UserApiKeysController`'s `sgu_` keys.
#
# ## Authorization is the association, and that is the whole of it
#
# Every read and write goes through `current_user.agent_api_keys`, so there is no id a signed-in
# person can type that reaches somebody else's key — the same rule `UserApiKeysController` states
# for its own table, and the reason neither controller carries a `RepositoryPolicy`: these keys
# hang off a person, and the only question a policy could ask is the one the association has
# already answered.
#
# ## The grant bound is the MODEL's, not this controller's
#
# A mint names a set of repositories and a set of permissions, and "may this person grant THAT?" is
# `RepositoryMembership#grantor_holds_every_granted_permission`'s question with the minting person
# in the grantor's seat — so it is validated where a membership grant is validated, on the model,
# and a refused mint surfaces the model's own sentences (which name the repository and the
# permission) rather than a controller paraphrase. This action attempts the save and reports
# whatever it says; re-checking any of it here would be a second copy of a rule that can drift.
#
# ## Reveal-once, its own mailbox
#
# The raw token rides the flash for exactly the redirect that follows, under this surface's OWN
# pair of keys — the third such pair, after `ApiKeysController`'s and `UserApiKeysController`'s,
# and for the same reason those two split: a flash is delivered to whatever request arrives next,
# and one shared namespace let an intervening page read (and mislabel) another surface's reveal.
# Only the SHA-256 digest reaches the database; `revealed_agent_api_key` stays a BARE token
# because the copy-text Stimulus controller copies that element's text verbatim.
#
# ## No `regenerate`, and revocation is a retirement
#
# No sibling of this controller offers rotation for a person-held credential, and an agent key has
# the least fixture of all: "I lost it" is mint another and revoke this one. And revoke is
# `AgentApiKey#revoke!` — a `revoked_at` stamp on a RETAINED row, the pattern `ApiKey#revoke!`
# established — so a still-presenting token stays attributable instead of resolving to nothing.
# The `destroy` action's name is Rails', not the act's.
class AgentApiKeysController < ApplicationController
  before_action :require_authentication

  # The id of the panel `accounts/_revealed_agent_token` renders — the same mechanism, and the
  # same reasoning, as `UserApiKeysController::REVEAL_ANCHOR`.
  REVEAL_ANCHOR = "revealed-agent-key"

  def create
    agent_api_key = current_user.agent_api_keys.new(agent_api_key_params)

    if agent_api_key.save
      flash[:revealed_agent_api_key] = agent_api_key.raw_token
      flash[:revealed_agent_api_key_name] = agent_api_key.name

      redirect_to account_path(anchor: REVEAL_ANCHOR),
                  notice: "Agent key created. Copy it now — it is shown only once."
    else
      # Redirect-with-flash rather than re-render: the mint form lives on `/account` beside the
      # key tables, and the model's sentences name the checkbox to fix, which is all a failed
      # mint needs to carry. Nothing was written, so there is nothing to clean up.
      redirect_to account_path(anchor: "agent-keys"),
                  alert: agent_api_key.errors.full_messages.to_sentence
    end
  end

  # Retires ONE key. Every other key this person holds keeps working: resolution is a lookup of
  # one digest on a unique index, so the rows know nothing about each other.
  def destroy
    current_user.agent_api_keys.find(params[:id]).revoke!

    redirect_to account_path, notice: "Agent key revoked."
  end

  private

  # A blank name defaults rather than failing, matching `UserApiKeysController#api_key_name`: the
  # name tells several keys apart on the revoke button, and a refusal over a blank field is a
  # worse answer than naming the key after what it is. `fetch` with a default rather than
  # `require`, on the same sibling's rule: a POST with no `agent_api_key` root at all is an
  # EMPTY MINT, which the model answers with its own sentence via the redirect below — not a 400
  # carrying a Rails exception, which is what a raised `ParameterMissing` would put on this
  # browser-facing form action.
  def agent_api_key_params
    params.fetch(:agent_api_key, {}).permit(:name, repository_ids: [], permissions: []).tap do |permitted|
      permitted[:name] = permitted[:name].presence || "Agent key"
    end
  end
end
