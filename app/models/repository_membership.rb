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

  before_validation :normalize_permissions

  validates :user_id, uniqueness: { scope: :repository_id, message: "already has a membership on this repository" }
  validate :permissions_are_known
  validate :user_is_not_the_owner

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
end
