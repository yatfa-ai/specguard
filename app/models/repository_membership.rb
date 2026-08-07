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

  # One condition, one sentence, named once. The read-then-write validation below and the
  # database-conflict translation in `#save` are two detections of the SAME fact, and they must
  # answer in the same words — the request spec's anti-collapse matrix asserts that each refusal
  # renders its own sentence and none of the others', so a second phrasing for this condition is a
  # regression by design.
  DUPLICATE_MESSAGE = "already has a membership on this repository"

  # The index that enforces the rule the message above explains, named so `#save` can tell this
  # conflict apart from any other unique violation the row might hit.
  DUPLICATE_INDEX = "index_repository_memberships_on_user_and_repository"

  belongs_to :user
  belongs_to :repository
  # Optional, and the validation below fails open on nil — see `grantor_holds_every_granted_permission`.
  belongs_to :granted_by_user, class_name: "User", optional: true,
                               inverse_of: :granted_repository_memberships

  before_validation :normalize_permissions

  validates :user_id, uniqueness: { scope: :repository_id, message: DUPLICATE_MESSAGE }
  validate :permissions_are_known
  validate :user_is_not_the_owner
  validate :grantor_holds_every_granted_permission

  # The uniqueness validation above is a read-then-write check: its SELECT runs before the INSERT,
  # so it cannot see a competing request that has not committed yet. Two concurrent adds for the
  # same person — a double-clicked "Add member", a re-submit on a slow connection — leave the loser
  # to be refused by the unique index instead, as `ActiveRecord::RecordNotUnique`, several layers
  # below anyone who is listening. There is no `rescue_from` anywhere in this app, so that reached
  # the 500 handler: a crash for the exact condition the sequential path answers with a sentence.
  #
  # Translated HERE rather than in `MembershipsController#create` for the reason that action's own
  # comment gives — "Re-checking any of them here would be a second copy of a rule that can drift
  # from the one the database is actually protected by". Every writer that goes through `#save`
  # inherits it: `#create`'s `return reject_grant(...) unless membership.save` and `#update`'s
  # `unless @membership.save` both re-render the form with the model's reasons, with no change to
  # either.
  #
  # `:user_id`, not `:base`, so the two detections are indistinguishable downstream — same
  # attribute, same words, and therefore the same `full_message` the controller renders.
  #
  # Only THIS conflict is translated. Any other unique violation is a different fault and is
  # re-raised: answering it with "already has a membership" would send the reader to fix something
  # that is not broken, and would report a clean refusal while the real fault stays hidden.
  #
  # A SAVEPOINT, for the same reason `Ingest::RunRecorder#create_run` opens one. Without
  # `requires_new` the INSERT merely *joins* whatever transaction the caller is already inside, and
  # Postgres aborts that entire transaction on a constraint violation — so rescuing the error would
  # hand the caller back a tidy `false` with a readable sentence on it while leaving the connection
  # refusing every subsequent statement with `PG::InFailedSqlTransaction`. That failure is worse
  # than the 500 this method exists to remove, because it reports success at refusing. The rescue
  # sits OUTSIDE the block deliberately: the `ROLLBACK TO SAVEPOINT` has to happen before anything
  # else touches the connection. Nothing wraps a membership save in a transaction today, so this
  # costs one round trip and buys the correctness for the day something does — and the suite alone
  # would never tell us, because transactional fixtures open non-joinable, which forces a savepoint
  # whether this asks for one or not. The model spec opens a real joinable transaction to pin it.
  #
  # `save!` is deliberately untouched — it does not route through here, and a caller who chose the
  # bang asked for the exception. The model spec pins that it still raises.
  def save(**)
    self.class.transaction(requires_new: true) { super }
  rescue ActiveRecord::RecordNotUnique => e
    raise unless e.message.include?(DUPLICATE_INDEX)

    errors.add(:user_id, DUPLICATE_MESSAGE)
    false
  end

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
  #
  # AND IT MUST NAME THE RIGHT ONE. `granted_by_user` has to be derived server-side from the
  # authenticated actor (the session's user), and must never be permitted through strong params or
  # otherwise taken from the request body. This validation trusts the grantor it is handed — a model
  # cannot know who made the HTTP request — so a form that permits `granted_by_user_id` lets a member
  # holding `members.manage` submit the *owner's* id, at which point the bound below is computed
  # against the owner's unlimited rights and every guarantee here evaporates. Worse than absent: the
  # save reports success, and the two-step escalation this validation exists to close is reopened
  # while the model still looks like it is defending against it.
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
