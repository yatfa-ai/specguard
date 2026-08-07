# frozen_string_literal: true

# The index the branch-scoped run history has been reading without.
#
# Added on MEASUREMENT, not on suspicion. `test_runs` carried only `[repository_id]` and a partial
# unique `[repository_id, ci_run_id]`, so every branch-scoped read — `previous_test_run_on_branch`
# for the Overview's suite-size delta, and now `suite_size_trajectory` for the growth chart — fell
# back to scanning the repository's whole run history, filtering it by branch, and top-N sorting
# the survivors. Correct, and linear in how long CI has been reporting.
#
# Measured on a seeded 40,000-run branch (plus an equal volume of other-branch noise, which is what
# the branch predicate has to skip), before and after:
#
#                              trajectory (LIMIT 30)   previous_test_run_on_branch (LIMIT 1)
#   no index                   12.9 ms                 12.7 ms
#   this index                  0.05 ms                 0.01 ms
#
# ...and the shape matters more than the multiple. Without it the cost grows with the branch's
# history — 0.29 ms at 800 runs, 2.1 ms at 8,000, 12.3 ms at 40,000 — because every matching row is
# read and sorted to find the newest thirty. With it the plan is an `Index Scan Backward` that stops
# after thirty entries, so the panel costs the same on a repository CI has reported to for a year as
# on one it reported to last week. Flat at 0.05 ms across all three sizes.
#
# The column order is the query's own: `repository_id` and `branch` are equalities, then
# `created_at, id` is exactly the ordering key both readers sort by, tie-break included — which is
# what lets the row-value comparison `(created_at, id) <= (?, ?)` be an index condition rather than
# a filter applied afterwards.
#
# Ascending, though both readers order DESC. Postgres scans a b-tree backwards at the same cost —
# verified: the ASC index plans `Index Scan Backward` at 0.053 ms against the DESC index's 0.069 ms
# — so the plain form is chosen for being the one that also serves an ascending reader later.
#
# `algorithm: :concurrently` so the build takes no write lock on a table ingestion writes to on
# every CI run. Requires `disable_ddl_transaction!`.
class AddBranchHistoryIndexToTestRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :test_runs, %i[repository_id branch created_at id],
              name: "index_test_runs_on_repository_id_and_branch_and_created_at",
              algorithm: :concurrently
  end
end
