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
class MembershipsController < ApplicationController
  before_action :require_authentication

  def index
    @repository = current_repository(:members_manage)
    # Ordered by handle so the list is stable between requests; `includes(:user)` because every row
    # renders the user's handle and avatar.
    @memberships = @repository.repository_memberships.includes(:user).joins(:user).order("users.github_handle")
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

    membership.destroy!

    # `members.manage` is not owner-only, so the holder can revoke *themselves* — that is their own
    # access to give up, and no check prevents it. But they have just 404'd themselves out of this
    # page, so send them somewhere that still exists. (They can never revoke the *owner*: an owner
    # membership row is impossible — see RepositoryMembership#user_is_not_the_owner — so that
    # invariant is structural, not a guard here.)
    if revoked_own_access
      redirect_to repositories_path, notice: "You no longer have access to #{repository.github_full_name}."
    else
      redirect_to repository_members_path(repository), notice: "Revoked #{handle}'s access."
    end
  end
end
