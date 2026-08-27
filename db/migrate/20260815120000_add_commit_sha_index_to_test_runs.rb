# frozen_string_literal: true

# The index `?commit_sha=` would otherwise read without.
#
# `Repository#latest_test_run_for_commit` — the finder `RepositoryOverview#latest_test_run`
# re-anchors on when a client names a run — is an equality on `(repository_id, commit_sha)` ordered
# by `(created_at, id)` DESC, taking one row. `test_runs` carried no index able to serve it:
# `[repository_id, branch, created_at, id]` is prefixed by a column this query does not constrain,
# and `[repository_id, ci_run_id]` is partial on a column it does not mention. So the plan fell back
# to the plain `[repository_id]` index, read EVERY run the repository has ever ingested, filtered
# them by sha in the executor, and sorted the two survivors to find the newer.
#
# Added on MEASUREMENT, not on suspicion, and by the same method the branch history index above
# documents — a seeded repository plus an equal volume of other-repository noise, best of five after
# three warm-ups, the target sha carrying TWO rows (a CI re-run, the case the finder's tie-break
# exists for) halfway back through the history:
#
#                    800 runs    8,000 runs    40,000 runs
#   no index          0.101 ms      0.680 ms       3.146 ms
#   this index        0.010 ms      0.010 ms       0.010 ms
#
# The SHAPE is the argument rather than the multiple, exactly as it was for the branch index. Without
# this, cost grows with how long CI has been reporting, because every run of the repository is read
# and discarded to find the two that match:
#
#   Sort  (Sort Key: created_at DESC, id DESC)
#     ->  Index Scan using index_test_runs_on_repository_id
#           Filter: commit_sha = '…'
#           Rows Removed by Filter: 40001
#
# With it the plan is an `Index Scan Backward` that stops after the first entry — no filter, no sort,
# nothing removed — so naming a run costs the same on a repository CI has reported to for a year as
# on one it reported to last week:
#
#   Index Scan Backward using index_test_runs_on_repository_id_and_commit_sha
#     Index Cond: (repository_id = … AND commit_sha = '…')
#
# It is worth the write cost where a `?spec_directory=` drill-in would not be, and the reason is
# where the parameter sits rather than how fast it is. This one re-anchors the memo EVERY OTHER BLOCK
# on the endpoint hangs off, so it is read before `latest_run`, the five rollups, the three drill-ins,
# both growth windows and `previous_test_run` — first in the request and on the critical path of all
# of them. A linear scan there is a linear scan of the whole response.
#
# The column order is the query's own: `repository_id` and `commit_sha` are the equalities, then
# `created_at, id` is exactly the ordering key the finder sorts by, tie-break included — which is
# what lets the LIMIT be satisfied by walking the index backwards rather than by sorting matches.
#
# Ascending, though the finder orders DESC, on the branch index's own finding: Postgres scans a
# b-tree backwards at the same cost, so the plain form is chosen for being the one that also serves
# an ascending reader later.
#
# NOT UNIQUE, and that is the table's shape rather than a relaxation. A sha is not unique in
# `test_runs` — the only unique index is `(repository_id, ci_run_id) WHERE ci_run_id IS NOT NULL`, so
# a CI re-run of one commit is a second row and a sharded suite reporting under one sha is several.
# That is precisely why the finder needs the ordering columns here at all: "the run for this sha" has
# more than one answer, and this index is what makes picking the newest of them free.
#
# `algorithm: :concurrently` so the build takes no write lock on a table ingestion writes to on every
# CI run. Requires `disable_ddl_transaction!`.
class AddCommitShaIndexToTestRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :test_runs, %i[repository_id commit_sha created_at id],
              name: "index_test_runs_on_repository_id_and_commit_sha",
              algorithm: :concurrently
  end
end
