# frozen_string_literal: true

# Who else can reach a repository: who holds it, the form that grants it, and the lever to take it
# away again.
#
# `index` and `destroy` are `members.manage` end to end — the table names people (GitHub handles,
# avatars), which is the same category as the credential metadata repositories#show already gates. A
# `view` member gets 403 on the page itself rather than a rendered page with the buttons hidden.
#
# `new`/`create` gate one step tighter, at `:owner`, and the split falls on a real line: revoking
# only ever de-escalates, whereas granting escalates. `RepositoryMembership`'s
# `grantor_holds_every_granted_permission` now bounds a grant by what the grantor holds, so a
# `members.manage` holder can no longer write `repo.delete` onto a row — but *who* may invite at all
# is a separate question from *what* an invite may contain, and widening this gate to
# `:members_manage` (rendering `grantable_permissions` rather than the full `PERMISSIONS` set) is its
# own slice. Under an owner the two sets are identical, so nothing here depends on the difference.
#
# Editing an existing member's permissions is the same checkbox grid and is likewise still absent.
#
# Revoking removes only the *web* half of access. A member who held `keys.manage` and minted a CI
# key keeps authenticating against the API afterwards — deliberately, see `User has_many
# :created_api_keys, dependent: :nullify`. So `index` and `destroy` also report how many keys the
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

  def new
    @repository = current_repository(:owner)
    @grant = MembershipGrant.new
  end

  # The first production call site `User.resolve_by_handle` has ever had, and the reason it returns a
  # four-way `Resolution` rather than a `User`: each of its three non-`found` answers is a different
  # fact about the world and earns a different sentence here. `:ambiguous` in particular is refused
  # outright — picking one of several rows sharing a recycled handle would silently grant a private
  # repository to a stranger, which is exactly what `User.resolve_by_handle` exists to make
  # impossible to do by accident.
  #
  # Everything past resolution is left to `RepositoryMembership`. Adding the owner, adding somebody
  # who is already a member, and naming a permission that does not exist are all already validations
  # on that model, so this attempts the save and surfaces whatever it says. Re-checking any of them
  # here would be a second copy of a rule that can drift from the one the database is actually
  # protected by.
  def create
    @repository = current_repository(:owner)
    @grant = MembershipGrant.new(grant_params.to_h)

    resolution = User.resolve_by_handle(@grant.handle)
    return reject_grant(unresolved_message(resolution)) unless resolution.found?

    membership = build_membership(resolution.user)
    return reject_grant(*membership.errors.map(&:full_message)) unless membership.save

    redirect_to repository_members_path(@repository), notice: grant_notice(membership)
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

  # `granted_by_user` is set HERE, from the session, and is deliberately absent from `grant_params`.
  # `RepositoryMembership#grantor_holds_every_granted_permission` bounds a grant by what the grantor
  # holds and trusts the grantor it is handed, so permitting this through the form would let a
  # request name the *owner* as grantor and compute the bound against unlimited rights — a save that
  # reports success while the escalation the validation exists to close is wide open. The model says
  # so itself: "Naming the grantor is therefore the writer's job."
  #
  # It is also why omitting it is not an option. That validation fails OPEN on a nil grantor (for the
  # console and the spec builders, which have no grantor to name), so a `create` that forgot it would
  # write the only rows in the product that the bound does not constrain at all.
  def build_membership(user)
    @repository.repository_memberships.new(
      user: user,
      permissions: @grant.permissions,
      granted_by_user: current_user
    )
  end

  # `permissions` is a `text[]`, and `[]` is the whole reason this is spelled out rather than left to
  # a scalar filter: a scalar `:permissions` silently DROPS the submitted array, and a membership
  # with no permissions is still a working membership (`view` is implied by the row itself — see
  # RepositoryPolicy#can?). So mis-permitting this does not raise and does not 422; it persists a
  # member who can open the repository and holds nothing else, and reads to the owner as "the
  # checkboxes do nothing". Pinned by the request spec, which asserts the stored array rather than
  # merely that a row appeared.
  def grant_params
    params.expect(membership_grant: [:handle, permissions: []])
  end

  # Re-renders the form with the reasons, and never with a redirect: the owner's typed handle and
  # ticked boxes live on `@grant` and would be gone after one.
  #
  # `:base` rather than per-attribute, because these arrive already phrased as whole sentences —
  # `RepositoryMembership`'s messages come through `full_message`, and the resolution's are written
  # below. Hanging them off `:handle` would prefix each one with "Handle" and turn "already owns this
  # repository" into a sentence about the wrong subject.
  def reject_grant(*messages)
    messages.each { |message| @grant.errors.add(:base, message) }

    render :new, status: :unprocessable_content
  end

  # One sentence per non-`found` resolution status. Collapsing any two of these is the failure
  # `User::Resolution` was built to prevent: "nobody has that handle" and "that is not a handle" send
  # the owner to fix entirely different things, and telling someone who pasted a profile URL to go
  # ask a colleague to re-authenticate is advice about the wrong problem.
  #
  # `else raise` on purpose, matching `RepositoryPolicy#can?`: a fifth status added to `Resolution`
  # must fail on the first request rather than fall through to a default that quietly accepts it.
  def unresolved_message(resolution)
    handle = @grant.handle.to_s.strip

    case resolution.status
    when :not_found
      "Nobody has signed into SpecGuard as #{handle} yet — ask them to sign in once, then add them."
    when :ambiguous
      "#{resolution.match_count} accounts share the handle #{handle}, so SpecGuard will not guess " \
        "which one you mean. Ask them to sign in again so their handle is current, then try again."
    when :malformed
      "That is not a GitHub handle. Enter the login itself — octocat, not a profile URL or a display name."
    else
      raise ArgumentError, "unhandled handle resolution #{resolution.status.inspect}"
    end
  end

  # Names what was actually stored rather than what was submitted: `normalize_permissions` strips and
  # de-duplicates, and a row can legitimately end up with none at all — which is worth saying, since
  # that member can still open the repository.
  def grant_notice(membership)
    handle = membership.user.github_handle
    return "Added #{handle}. They can open #{@repository.github_full_name}." if membership.permissions.empty?

    "Added #{handle} with #{membership.permissions.to_sentence}."
  end

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
