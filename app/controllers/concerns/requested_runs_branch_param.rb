# frozen_string_literal: true

# `?runs_branch=` read as a branch name for the "Recent runs" panel on `repositories#show`, or
# `nil` for "no ask" — the panel then renders the one interleaved all-branch window it always has.
#
# Deliberately its own module and NOT an overload of `?branch=` (`RequestedBranchParam`): that
# parameter selects the Suite-growth trajectory's series, is carried by every existing
# `drill_down_path` link on the page, and widening its meaning would silently re-point a panel a
# reader has already aimed. One parameter per panel, on the same reasoning every `Requested*Param`
# sibling gives; the two asks are free to compose (`?branch=` picks the trajectory's series,
# `?runs_branch=` picks this panel's rows) precisely because neither redefines the other. Not a
# reuse of `?runs=` or `?limit=` either — those are magnitude asks over the rows this one filters,
# and the three compose rather than compete.
#
# What it shares with every sibling is the hazard, and the guard is the same lines in the same
# order as `RequestedBranchParam#requested_branch`:
#
# * `is_a?(String)` first — `?runs_branch[]=main`, `?runs_branch[a]=b` and
#   `?runs_branch[][a]=b` parse to an Array, to `ActionController::Parameters` and to an Array of
#   them, and none of those is an ask. They are treated as no ask, the same answer an absent param
#   gets, rather than reaching a `where` that raises — a 500 on a URL anyone can type into the bar.
# * No NUL, second — `?runs_branch=ma%00in` parses to a String and answers `.presence` like any
#   other, but Postgres cannot hold a NUL in a text value, so no row could ever match the ask and
#   the `where` it reaches raises before anything answers. Treated as no ask, like the shapes above.
# * `.presence` last, which is what makes `?runs_branch=` mean "no ask" rather than
#   `WHERE branch = ''` — and keeps any input at all from reaching a `WHERE branch IS NULL`.
#   `branch` is nullable and an anonymous run is an ordinary live state, so NULL is "the reporter
#   did not say" and not a branch anyone can ask for. `Repository#recent_test_runs` makes the same
#   guard on its own side; this one is here so the model is never handed a blank in the first place.
#
# No validation and no 400, for the reason `RequestedBranchParam` gives in full: an unknown branch
# is not a malformed request, it is a request whose answer is zero rows — and zero rows is the
# honest answer, because substituting another branch's rows would hand back a window for the wrong
# branch with nothing in the result to say so. The panel renders that emptiness and says which
# branch was asked; a typo, a deleted branch and a stale bookmark are ordinary ways to arrive.
module RequestedRunsBranchParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, for the reason every sibling gives: `nil` is the
  # common answer and `||=` would re-read the params on every call.
  def requested_runs_branch
    return @requested_runs_branch if defined?(@requested_runs_branch)

    raw = params[:runs_branch]
    @requested_runs_branch = raw.is_a?(String) && !raw.include?("\u0000") ? raw.presence : nil
  end
end
