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
#
# That disclosure is gated on `keys.manage`, NOT on the `members.manage` that gates the page —
# see `keys_minted_by`. The two permissions are independent, so "who can reach this repository"
# and "how many credentials exist on it" are separate questions and this page may only answer the
# first to a viewer who holds only `members.manage`.
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
      redirect_to repository_members_path(repository), notice: helpers.revoke_notice(handle, keys_minted)
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
  #
  # The `keys.manage` gate is the load-bearing line, and it lives HERE rather than at the two call
  # sites for the same reason `current_repository` resolves and authorizes together: a caller that
  # forgets it is a leak, and both callers need it. `members.manage` and `keys.manage` are
  # independent permissions, so a viewer can hold this page without holding any right to key
  # metadata — and `RepositoriesController#key_count_visible?` already states the rule this obeys:
  # "repositories#show gates the whole API keys panel behind `keys.manage`, so a bare count would
  # leak past the same line." A count on *this* page is the same count. An empty hash makes every
  # surface downstream degrade to the zero-key wording, which is exactly right: a viewer who may
  # not know the number should be told nothing, not told less.
  #
  # This also keeps the badge's deep link honest. It points at `#api-keys` on repositories#show,
  # a panel that renders only under the same `keys.manage` — so gating on anything wider would
  # render an affordance that lands on a page where the panel, the anchor and the Revoke button
  # it promises all do not exist.
  #
  # `repository_policy` is memoized per repository and already populated by `current_repository`
  # above, so this asks the database nothing.
  def keys_minted_by(repository, user_ids)
    return {} unless repository_policy(repository).can?(:keys_manage)
    return {} if user_ids.empty?

    repository.api_keys.where(created_by_user_id: user_ids).group(:created_by_user_id).count
  end
end
