# frozen_string_literal: true

# Who else can reach a repository, and the lever to take that away again.
#
# Both actions are `members.manage` end to end — the table names people (GitHub handles, avatars),
# which is the same category as the credential metadata repositories#show already gates. A `view`
# member gets 403 on the page itself rather than a rendered page with the buttons hidden.
#
# The counterpart controls (add a colleague by handle, edit an existing member's permissions) are
# deliberately absent: they are the same checkbox grid, and both need `User.resolve_by_handle`,
# which is not merged yet. Until it is, *remove* is the lever this page offers.
#
# Revoking removes only the *web* half of access. A member who held `keys.manage` and minted a CI
# key keeps authenticating against the API afterwards — deliberately, see `User has_many
# :created_api_keys, dependent: :nullify`. So both actions here also report how many keys the
# member minted: the page and the confirm dialog before the click, the flash after it. The
# judgement stays with the owner, who holds the actual lever in the API keys panel; what this
# closes is their having no way to know they need to pull it.
class MembershipsController < ApplicationController
  before_action :require_authentication

  def index
    @repository = current_repository(:members_manage)
    # Ordered by handle so the list is stable between requests; `includes(:user)` because every row
    # renders the user's handle and avatar.
    @memberships = @repository.repository_memberships.includes(:user).joins(:user).order("users.github_handle")
    @keys_minted = keys_minted_by(@repository, @memberships.map(&:user_id))
  end

  # Scoped through `repository.repository_memberships`, exactly as ApiKeysController#destroy scopes
  # through `repository.api_keys`, and for the same reason — but the trap is sharper here. On this
  # nested route `params[:id]` is a *membership* id while `current_repository` authorized against
  # `params[:repository_id]`, so a global `RepositoryMembership.find(params[:id])` would let a
  # holder of `members.manage` on one repository delete a membership belonging to another. The
  # scoped lookup makes that a 404 instead. See the cross-repository example in the request spec.
  def destroy
    repository = current_repository(:members_manage)
    membership = repository.repository_memberships.find(params[:id])
    revoked_own_access = membership.user_id == current_user.id
    handle = membership.user.github_handle
    # Read before the row goes away. Destroying a membership does not touch an api_keys row — only
    # destroying the *user* nullifies `created_by_user_id` — so this count is stable either side of
    # the destroy. Taking it first keeps the notice's claim and the state it describes in one place.
    keys_minted = keys_minted_by(repository, [membership.user_id]).fetch(membership.user_id, 0)

    membership.destroy!

    # `members.manage` is not owner-only, so the holder can revoke *themselves* — that is their own
    # access to give up, and no check prevents it. But they have just 404'd themselves out of this
    # page, so send them somewhere that still exists. (They can never revoke the *owner*: an owner
    # membership row is impossible — see RepositoryMembership#user_is_not_the_owner — so that
    # invariant is structural, not a guard here.)
    if revoked_own_access
      redirect_to repositories_path, notice: "You no longer have access to #{repository.github_full_name}."
    else
      redirect_to repository_members_path(repository), notice: revoke_notice(handle, keys_minted)
    end
  end

  private

  # `user_id => live key count`, for the whole table in ONE grouped query — the same N+1 discipline
  # as `RepositoriesController#shared_permissions` ("the same answer in a single query"), because a
  # per-row count would cost one query per member.
  #
  # Scoped through `repository.api_keys`, so it can never read another repository's keys, and it
  # counts what is *live*: revoking a key deletes the row, so a member whose keys have all been
  # revoked drops out of the hash entirely and reads as zero.
  def keys_minted_by(repository, user_ids)
    return {} if user_ids.empty?

    repository.api_keys.where(created_by_user_id: user_ids).group(:created_by_user_id).count
  end

  # Revoking a membership deliberately leaves that member's API keys authenticating — see
  # `User has_many :created_api_keys, dependent: :nullify`, and the request spec that locks the
  # behaviour in. The owner already holds the lever (Revoke, in the API keys panel); what they
  # lacked was any signal that it needs pulling. Zero-key members keep the original one-sentence
  # notice verbatim rather than being told about a consequence that did not happen.
  def revoke_notice(handle, keys_minted)
    return "Revoked #{handle}'s access." if keys_minted.zero?

    "Revoked #{handle}'s access. #{helpers.pluralize(keys_minted, "API key")} they minted " \
      "#{keys_minted == 1 ? "is" : "are"} still live — review " \
      "#{keys_minted == 1 ? "it" : "them"} in the API keys panel."
  end
end
