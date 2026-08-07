# frozen_string_literal: true

# The "add a member by GitHub handle" form's own object.
#
# Deliberately NOT a RepositoryMembership. The form's first field is a *typed handle*, which is not
# an attribute of that row and must not become one: `User.resolve_by_handle` may answer that nobody
# holds it, that several people do, or that GitHub could never have issued it, and none of those
# three has a `user_id` to build a membership from. Holding the typed string here is what lets the
# form re-render with what the owner actually typed while no half-built membership row ever exists.
#
# It carries the errors too, for the same reason. A failed grant has three different sources of
# failure — the resolution, the model's validations, and the form itself — and the owner should read
# one list, not hunt across two objects. `MembershipsController#create` copies the model's messages
# here verbatim rather than restating them, so "you already own this repository" stays one sentence
# owned by `RepositoryMembership`.
class MembershipGrant
  include ActiveModel::Model

  attr_accessor :handle
  attr_writer :permissions

  # Always an Array, so the checkbox grid can ask which boxes are ticked before anything has been
  # submitted. The values are left exactly as they arrived — stripping and de-duplicating them is
  # `RepositoryMembership#normalize_permissions`'s job, and doing it again here would be a second
  # copy of that rule to keep in step.
  def permissions = Array(@permissions)
end
