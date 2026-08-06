# frozen_string_literal: true

# The single authorization question for a repository: "may this user do this to it?"
#
# A plain PORO rather than Pundit: the surface is four permissions asked in two controllers, which
# does not justify a gem plus an initializer plus a base-policy convention.
#
# Capabilities are symbols (`:keys_manage`) and map onto the stored permission strings
# (`"keys.manage"`). Asking for an unknown capability raises rather than quietly denying — a typo
# in a controller must fail on the first request, not silently lock everyone out.
class RepositoryPolicy
  # Owner-only. A distinct sentinel rather than `nil`, so that `CAPABILITIES[:owner]` is never
  # indistinguishable from a key that isn't there — an unknown capability has to stay loud (see
  # the `fetch` block below). No membership permission maps to it, so a member never passes however
  # the row is configured. Repository rename lives here: `github_full_name` is both the repo's
  # identity and the global unique key, so renaming stays with the owner for v1.
  OWNER_ONLY = :owner_only

  CAPABILITIES = {
    view: RepositoryMembership::VIEW,
    keys_manage: RepositoryMembership::KEYS_MANAGE,
    members_manage: RepositoryMembership::MEMBERS_MANAGE,
    repo_delete: RepositoryMembership::REPO_DELETE,
    owner: OWNER_ONLY
  }.freeze

  # CAPABILITIES read backwards, for the permissions a membership row can actually store. `:owner`
  # is excluded because OWNER_ONLY is a sentinel rather than a storable string — inverting it would
  # put a non-permission on the left-hand side of a map whose whole job is to translate stored
  # permissions.
  CAPABILITY_BY_PERMISSION = CAPABILITIES.except(:owner).invert.freeze

  attr_reader :user, :repository

  def initialize(user, repository)
    @user = user
    @repository = repository
  end

  def owner?
    user.present? && repository.present? && repository.user_id == user.id
  end

  # The 404-vs-403 fork: a non-member must not learn the repository exists, whereas a member who
  # merely lacks one permission already knows, so telling them 404 would be a lie.
  def member?
    owner? || membership.present?
  end

  def can?(capability)
    permission = CAPABILITIES.fetch(capability.to_sym) do
      raise ArgumentError, "unknown repository capability #{capability.inspect}"
    end

    return true if owner?
    return false if membership.nil?
    return false if permission == OWNER_ONLY

    # `view` is implied by the membership itself. A row granting only "keys.manage" would otherwise
    # be incoherent — manage the keys of a repository you are not allowed to open. Storing "view"
    # explicitly stays valid (and is what the members UI will write); it just isn't what decides.
    return true if permission == RepositoryMembership::VIEW

    membership.permissions.include?(permission)
  end

  # What this user may hand to somebody else: the bound `RepositoryMembership` validates a grant
  # against, and the set an "add/edit member" form should render checkboxes from — so the grid
  # offers only what the save will accept, rather than options that are rejected on submit.
  #
  # Derived from `can?` rather than read off the row, which is what keeps the answer honest for a
  # member whose row omits "view": membership itself grants view (see `can?`), so they may delegate
  # it. Deriving it here from the stored strings instead would make "what a grant may contain" and
  # "what a membership yields" two rules that can drift.
  #
  # A non-member — including a nil user or a nil repository — may grant nothing.
  #
  # `fetch` with no default on purpose: a permission added to `RepositoryMembership::PERMISSIONS`
  # without a matching capability raises here, exactly as `can?` raises on a capability that does
  # not exist. Silently omitting it would make the new permission ungrantable forever, and nothing
  # would say so.
  def grantable_permissions
    RepositoryMembership::PERMISSIONS.select { |permission| can?(CAPABILITY_BY_PERMISSION.fetch(permission)) }
  end

  private

  # Deliberately private: the class's API is `owner?` / `member?` / `can?`. The row is how those are
  # computed, not something a caller should reach through the policy to read.
  def membership
    return @membership if defined?(@membership)

    @membership =
      if user.nil? || repository.nil?
        nil
      else
        RepositoryMembership.find_by(user_id: user.id, repository_id: repository.id)
      end
  end
end
