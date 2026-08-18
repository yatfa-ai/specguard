# frozen_string_literal: true

# `?commit_sha=` read as a commit sha, or `nil` for "no ask".
#
# The sixth `Requested*Param`, and the first that re-anchors WHICH RUN the response describes rather
# than narrowing what is served about the run it already picked. The five siblings all take the
# anchor as given: `?branch=` narrows a history, and the three drill-in parameters open one area,
# one file or one description OF THE RUN `Api::V1::RepositoriesController#latest_test_run` had
# already chosen. This one chooses that run — which is why it is read in exactly one place, the
# memo itself, and why every dependent block follows without reading it at all.
#
# Deliberately its own module rather than a widening of any sibling, on the rule
# `RequestedSpecFileParam` states in full: one module per parameter, because the parameters mean
# different things and one guard answering several of them would make "which shapes does each
# tolerate" a single question nobody asked. What they share is the hazard, and the guard for it is
# the same two lines in the same order.
#
# `is_a?(String)` FIRST, and it is not defensive noise: `?commit_sha[]=x` parses to an Array,
# `?commit_sha[a]=b` to `ActionController::Parameters` and `?commit_sha[][a]=b` to an Array of them,
# and none of the three answers `.presence` the way this reads it. This one reaches a
# `where(commit_sha: …)` on a plain string column directly, so an Array would not raise: it would
# quietly become an `IN` list, and here that is the silent wrong answer at its worst — the endpoint
# would anchor on whichever of several unrelated commits happened to sort newest and serve every
# rollup, every drill-in and both growth windows against it, under a `run_anchor` naming one sha the
# client asked for. Anything that is not a String is treated as no ask, which is the same answer an
# absent param gets: the endpoint anchors on the repository's newest run exactly as it did before
# the parameter existed. All three shapes are pinned; see
# `spec/support/shared_examples/malformed_commit_sha_param.rb`.
#
# `.presence` SECOND, which is what makes `?commit_sha=` mean "no ask" rather than
# `WHERE commit_sha = ''`. `test_runs.commit_sha` is NOT NULL and is the one attribute `TestRun`
# validates the presence of, so no row can carry a blank — an empty ask is guaranteed to resolve to
# nothing, and the fallback would then serve the newest run while `run_anchor` claimed a request had
# been made. "The client sent an empty parameter" and "the client named a sha we have no run for"
# are different facts, and only the second is worth disclosing.
#
# No validation branch and no 404, and no shape check on the sha either. A sha this repository has
# no run for is not a malformed request — a stale bookmark, a pruned run and a commit whose CI never
# reported are all ordinary ways to arrive, and `Api::V1::RepositoriesController#serialized_run_anchor`
# answers them by falling back to the newest run and SAYING SO (`source: "requested"`,
# `resolved: false`). That is the stance `RepositoriesController`'s `@trajectory_branch_request`
# takes for the same shape of ask on the human page. Nor does this care whether the string looks
# like a sha: `commit_sha` is a plain `string` column written from whatever CI reported, short
# form and long form both, so a length or hex check here would reject values the table holds.
module RequestedCommitShaParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — no ask — is the common answer on
  # this endpoint and `||=` would re-read the params on every call. The same idiom, for the same
  # reason, as `RequestedBranchParam#requested_branch`.
  def requested_commit_sha
    return @requested_commit_sha if defined?(@requested_commit_sha)

    raw = params[:commit_sha]
    @requested_commit_sha = raw.is_a?(String) ? raw.presence : nil
  end
end
