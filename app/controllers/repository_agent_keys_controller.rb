# frozen_string_literal: true

# THE REPOSITORY-SIDE REVOKER FOR THE AGENT CREDENTIAL (SPGD-989) — SPGD-112's rule carried to
# the third credential kind. The `sgk_` table already gives a repository's `keys.manage` holders
# the lever over a departing member's keys (`ApiKeysController#destroy`); an `sga_` key minted by
# a member whose membership was later revoked outlived their access exactly the same way, and its
# only revoker was its owner, from `/account`. When that owner is gone or gone quiet, the key
# authenticates indefinitely over a repository nobody could retire it from. This is that lever.
#
# ## Why the authorization is NEW, and not `AgentApiKeysController`
#
# `AgentApiKeysController` authorizes through the `current_user.agent_api_keys` association alone
# — the right authority for a person retiring their OWN credential, and the wrong one for a
# repository-admin act: it would let a person revoke a key whose set they hold no `keys.manage`
# over, and refuse a keys.manage holder revoking somebody else's key that covers their
# repository. Here the authority is the repository's: `current_repository(:keys_manage)` — the
# same gate that renders the listing and that already revokes `sgk_` keys — plus a `covers?`
# check binding the KEY to THIS repository, so a keys.manage holder of repo A cannot revoke a key
# whose set excludes A. Out-of-boundary answers 404, the same nil-is-404 fork every repository
# read takes: the refusal says nothing about a key the caller has no business knowing exists.
#
# ## One act, honestly disclosed
#
# `revoke!` on a multi-repository key cuts the token EVERYWHERE — the set is one grant, stored
# once. The confirm dialog on the listing names the key's FULL stored set (count and names)
# before the cut for exactly that reason, the members-page revoke dialog's one-act honesty. What
# the trigger requires is `keys.manage` over THIS repository, not over the whole set — the
# disclosure, not a wider gate, is the mechanism (SPGD-112's precedent: the sgk_ revoker asks
# this repository's permission and says what will happen). Requiring every repository would
# strand an outliving key whenever no single person holds keys.manage across the set — the exact
# unrevokable-credential failure this controller exists to end.
#
# LIVE keys only: a revoked row is retained but is not a credential, `MembershipsController#
# keys_minted_by` already refuses to count one, and the listing offers the button on live rows
# alone — so a replayed DELETE finds nothing here, on the usual `find` 404. `revoke!` itself is
# idempotent; this action simply has no reason to reach a retired row.
class RepositoryAgentKeysController < ApplicationController
  before_action :require_authentication

  def destroy
    repository = current_repository(:keys_manage)
    agent_api_key = AgentApiKey.live.find(params[:id])
    raise ActiveRecord::RecordNotFound unless agent_api_key.covers?(repository)

    agent_api_key.revoke!
    redirect_to repository_path(repository),
                notice: helpers.agent_key_revoke_notice(agent_api_key,
                                                        agent_api_key.repositories
                                                                     .order(:github_full_name)
                                                                     .pluck(:github_full_name))
  end
end
