# frozen_string_literal: true

# `?compare_to=<branch>` read as a branch name, or `nil` for "no ask" — the page's run-pair
# figures ("What changed", SPGD-1981) are then measured against the newest run on the NAMED
# branch at or before the run being read, instead of the same-branch predecessor they fall back
# to.
#
# Deliberately its own module and NOT an overload of `?branch=` (`RequestedBranchParam`): that
# parameter selects the Suite-growth trajectory's series, is carried by every existing
# `drill_down_path` link on the page, and widening its meaning would silently re-point a panel a
# reader has already aimed — the exact argument `RequestedRunsBranchParam` makes for itself, and
# one parameter per panel on the same reasoning every `Requested*Param` sibling gives. The two
# asks compose (`?branch=feat&compare_to=main` draws feat's history and measures feat's run
# against main) precisely because neither redefines the other.
#
# What it shares with every sibling is the hazard, and the guard is the same lines in the same
# order as `RequestedBranchParam#requested_branch`:
#
# * `is_a?(String)` first — `?compare_to[]=main`, `?compare_to[a]=b` and `?compare_to[][a]=b`
#   parse to an Array, to `ActionController::Parameters` and to an Array of them, and none of
#   those is an ask. They are treated as no ask, the same answer an absent param gets, rather
#   than reaching a `where` that raises — a 500 on a URL anyone can type into the bar.
# * No NUL, second — `?compare_to=ma%00in` parses to a String and answers `.presence` like any
#   other, but Postgres cannot hold a NUL in a text value, so no row could ever match the ask and
#   the `where` it reaches raises before anything answers. Treated as no ask, like the shapes
#   above.
# * `.presence` last, which is what makes `?compare_to=` mean "no ask" rather than a comparison
#   against a branch whose name is the empty string — and keeps any input at all from reaching a
#   `WHERE branch IS NULL`. `branch` is nullable and an anonymous run is an ordinary live state,
#   so NULL is "the reporter did not say" and not a branch anyone can ask for.
#
# No validation and no 400, for the reason `RequestedBranchParam` gives in full: an unknown
# branch is not a malformed request, it is a request whose answer is "no run of that branch to
# measure against" — and that answer is stated on the page rather than substituted away, because
# silently measuring against a DIFFERENT branch than the URL names is the one falsehood this
# parameter must never produce. `RepositoryDashboard` keeps the raw ask in
# `@comparison_baseline_request` for exactly that reason, the way `@trajectory_branch_request`
# keeps its own.
module RequestedCompareToParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, for the reason every sibling gives: `nil` is the
  # common answer and `||=` would re-read the params on every call.
  def requested_compare_to
    return @requested_compare_to if defined?(@requested_compare_to)

    raw = params[:compare_to]
    @requested_compare_to = raw.is_a?(String) && !raw.include?("\u0000") ? raw.presence : nil
  end
end
