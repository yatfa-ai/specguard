# frozen_string_literal: true

# `?role=` read as one of the two ownership states the index card badge already draws — `owned` or
# `shared` — or `nil` for "no ask" (both, the page's whole population).
#
# Deliberately its own module rather than a widening of any sibling `Requested*Param`, and one
# module per parameter is the point of the split — the argument `RequestedSpecFileParam` makes for
# itself and every later sibling makes again. What they share is the hazard, not the subject.
#
# `is_a?(String)` FIRST, on every sibling's reasoning: `?role[]=x` parses to an Array and
# `?role[a]=b` to `ActionController::Parameters`, and neither is an ownership state. Anything that
# is not a String is treated as no ask — the same answer an absent param gets. All three shapes
# are pinned; see `spec/support/shared_examples/malformed_role_param.rb`.
#
# `.presence` SECOND, so `?role=` — a select submitted at its default, a hand-built query string
# with a nil in it — is not an ask.
#
# THEN THE VOCABULARY CLAMP, which is what makes this sibling different from the key-named ones:
# a String that names no state (`?role=admin`, `?role=owner`, a typo) reads as no ask rather than
# as an error, for the same reason a blank does. There is nothing here for a client to correct
# that a missing param would not equally have — the page has exactly two states to offer and a
# reader cannot have meant a third one, so an unknown spelling is a stale bookmark or a typo and
# answers with the ordinary page. The clamp is why the malformed shared example carries
# out-of-vocabulary strings beside the container shapes: "reads as no ask" is one behavior with
# two families of input, and pinning only the containers would leave the string half unguarded.
#
# `ROLES` is frozen and lives here rather than in the view, because it is the READ's vocabulary:
# the select that emits `?role=` is populated from the same words, and the one place they are
# defined is the guard that decides what they mean.
module RequestedRoleParam
  extend ActiveSupport::Concern

  # The states the page offers. `owned` is `user_id = current_user.id`; `shared` is its complement
  # within `accessible_by`. The complement is deliberately not a third state here — "absent reads
  # as both" is the nil ask, and encoding it as a value would make `nil` and `""` mean different
  # things for one parameter on one page.
  ROLES = %w[owned shared].freeze

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — no ask — is the common answer on
  # this page and `||=` would re-read the params on every call. The same idiom, for the same
  # reason, as `RequestedBranchParam#requested_branch`.
  def requested_role
    return @requested_role if defined?(@requested_role)

    raw = params[:role]
    @requested_role = if raw.is_a?(String) && (ask = raw.presence)
                        ROLES.include?(ask) ? ask : nil
                      end
  end
end
