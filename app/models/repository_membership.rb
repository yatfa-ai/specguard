# frozen_string_literal: true

# Grants one user access to a repository they do not own.
#
# The owner is deliberately *not* represented here: `Repository#user_id` already says who owns it,
# and the owner holds every permission implicitly (see RepositoryPolicy). A membership row for the
# owner would be a second, contradictable source of truth, so it is rejected outright.
class RepositoryMembership < ApplicationRecord
  VIEW = "view"
  KEYS_MANAGE = "keys.manage"
  MEMBERS_MANAGE = "members.manage"
  REPO_DELETE = "repo.delete"

  PERMISSIONS = [VIEW, KEYS_MANAGE, MEMBERS_MANAGE, REPO_DELETE].freeze

  belongs_to :user
  belongs_to :repository
  # Optional, and the validation below fails open on nil — see `grantor_holds_every_granted_permission`.
  belongs_to :granted_by_user, class_name: "User", optional: true,
                               inverse_of: :granted_repository_memberships

  before_validation :normalize_permissions

  validates :user_id, uniqueness: { scope: :repository_id, message: "already has a membership on this repository" }
  validate :permissions_are_known
  validate :user_is_not_the_owner
  validate :grantor_holds_every_granted_permission

  private

  # Free-form array columns collect whitespace and duplicates the moment a form writes to them.
  def normalize_permissions
    self.permissions = Array(permissions).map { |permission| permission.to_s.strip }.reject(&:empty?).uniq
  end

  def permissions_are_known
    unknown = permissions - PERMISSIONS
    return if unknown.empty?

    errors.add(:permissions, "contains unknown #{'value'.pluralize(unknown.size)}: #{unknown.join(', ')}")
  end

  def user_is_not_the_owner
    return if user_id.blank? || repository.nil?
    return unless repository.user_id == user_id

    errors.add(:user, "already owns this repository")
  end

  # Nobody may grant access they do not themselves hold.
  #
  # Without this, `members.manage` ("add/remove collaborators, edit permissions") is a lever to
  # every other permission: its holder can write `repo.delete` onto their own row and then destroy
  # the owner's repository, taking every API key, test run and spec intent with it through
  # `Repository`'s `dependent: :destroy`. Two steps, and until now no gate at either.
  #
  # The bound comes from `RepositoryPolicy#grantable_permissions` rather than being re-derived from
  # the permission strings here, so "what a grant may contain" and "what a membership yields" stay
  # one rule instead of two that drift. That also means the grantor's rights are read from the
  # *persisted* row: a member editing their own membership is measured against what they hold now,
  # not against what this save is trying to give them, so a grant cannot bootstrap itself.
  #
  # FAILS OPEN on a nil grantor. A row saved without one persists exactly as it did before this
  # column existed — the same "legacy rows read Unknown" semantics already accepted for
  # `api_keys.created_by_user_id`. Memberships are written today only by the spec builders and the
  # console, neither of which has a grantor to name, and failing closed would break both. Naming the
  # grantor is therefore the *writer's* job: the controller that adds or edits members must set it
  # explicitly, and must not rely on this validation to notice that it forgot.
  def grantor_holds_every_granted_permission
    return if granted_by_user.nil? || repository.nil?

    # Intersected with PERMISSIONS so an unknown value is reported once, by `permissions_are_known`,
    # rather than twice under two different explanations ("unknown" and "you don't hold it").
    ungrantable = (permissions & PERMISSIONS) - RepositoryPolicy.new(granted_by_user, repository).grantable_permissions
    return if ungrantable.empty?

    errors.add(
      :permissions,
      "includes #{'permission'.pluralize(ungrantable.size)} the grantor does not hold: #{ungrantable.join(', ')}"
    )
  end
end
