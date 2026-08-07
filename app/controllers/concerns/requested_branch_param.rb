# frozen_string_literal: true

# `?branch=` read as a branch name, or `nil` for "no ask".
#
# ONE MODULE, TWO BASES — the same argument `ShardCountPreloading` makes for itself. This is
# included into both an `ActionController::Base` (the suite-trajectory panel on repositories#show)
# and an `ActionController::API` (the `history` block on `GET /api/v1/repository`). It reads
# `params` and nothing else — no view helper, no session, nothing an `ActionController::API` lacks
# — so the differing bases were never an obstacle to sharing, which is why this is a module rather
# than the two verbatim copies it replaces. Do not let it grow a reach that changes that.
#
# `is_a?(String)` FIRST, and it is not defensive noise: `?branch[]=main` parses to an Array,
# `?branch[a]=b` to `ActionController::Parameters` and `?branch[][a]=b` to an Array of them, and
# none of the three answers `.presence` the way this reads it — an unguarded
# `params[:branch].presence` turns a malformed query string into a 500 on an authenticated GET, on
# a URL anyone can type into the bar. Anything that is not a String is treated as no ask, which is
# the same answer an absent param gets: the API reports `branch_scope: "all_branches"` and the page
# renders exactly what it rendered before the parameter existed. Both surfaces pin all three shapes
# — see `spec/support/shared_examples/malformed_branch_param.rb`.
#
# `.presence` SECOND, which is what makes `?branch=` mean "no ask" rather than `WHERE branch = ''`
# — and, critically, keeps any input at all from reaching a `WHERE branch IS NULL`. `branch` is
# nullable and an anonymous run is an ordinary live state, so NULL is "the reporter did not say"
# (the meaning `Api::V1::RepositoriesController#serialized_history_row` pins) and not a branch
# anyone can ask for. `Repository#recent_test_runs` makes the same guard on its own side; this one
# is here so the model is never handed a blank in the first place.
#
# No validation branch and no 400: an unknown branch is not a malformed request, it is a request
# whose answer is zero rows on the API and the unfiltered fallback on the page. See
# `Api::V1::RepositoriesController#serialized_history` for why `[]` is the right answer there and
# why a substituted branch's rows would be the dangerous one. `repositories#show` keeps the raw ask
# in `@trajectory_branch_request` for the same reason — so the panel can SAY the fallback happened,
# rather than quietly drawing a different branch from the one the URL names.
module RequestedBranchParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, because `nil` is the common answer and `||=` would
  # re-read the params on every call. Load-bearing on the API side, which asks five times per
  # request (`branch_scope`, `branch`, `history_limit`, `recent_test_runs`, `branch_histories`);
  # merely free on the human side, which asks once.
  def requested_branch
    return @requested_branch if defined?(@requested_branch)

    raw = params[:branch]
    @requested_branch = raw.is_a?(String) ? raw.presence : nil
  end
end
