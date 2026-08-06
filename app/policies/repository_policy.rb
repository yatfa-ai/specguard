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
  # Owner-only. No membership permission maps to it, so a member never passes however the row is
  # configured. Repository rename lives here: `github_full_name` is both the repo's identity and
  # the global unique key, so renaming stays with the owner for v1.
  OWNER_ONLY = nil

  CAPABILITIES = {
    view: RepositoryMembership::VIEW,
    keys_manage: RepositoryMembership::KEYS_MANAGE,
    members_manage: RepositoryMembership::MEMBERS_MANAGE,
    repo_delete: RepositoryMembership::REPO_DELETE,
    owner: OWNER_ONLY
  }.freeze

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
