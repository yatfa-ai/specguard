# frozen_string_literal: true

# Priming `TestRun#shard_count` across a whole window of runs in ONE aggregate, for any surface
# that names how each of several runs was assembled.
#
# Every route to that fact on the model — `TestRun#shard_count`, `#multi_shard?`,
# `#delivery_description` — goes through a memoized per-instance `pick`. Asked once per row, that
# is one query per row for one column, and it is the kind of N+1 that ships green: a query-budget
# example whose fixture holds one run, or none, cannot see it at all.
#
# `group(:test_run_id).count` runs on `index_test_run_shards_on_test_run_id` (db/schema.rb), keyed
# by the ids already loaded. A run with no shard rows — the whole unsharded corpus, every run that
# named no `ci_run_id` — is simply absent from the hash and is primed with the zero
# `TestRun#delivery_description` already words as "reported in one piece".
#
# Returns early on an empty list rather than letting `where(test_run_id: [])` issue a `WHERE 1=0`:
# a repository that has never ingested should pay nothing for a window of no rows.
#
# ONE MODULE, TWO BASES. This is included into both an `ActionController::Base` (the human Recent
# runs panel) and an `ActionController::API` (the `history` block on `GET /api/v1/repository`).
# Nothing in the four lines below touches view helpers or anything an API controller lacks, so the
# differing bases were never an obstacle to sharing — which is why this is a module rather than the
# two verbatim copies it replaces.
module ShardCountPreloading
  extend ActiveSupport::Concern

  private

  # Primes the COUNT ALONE and never the rest of `shard_totals` — `TestRun#preload_shard_count`
  # documents that narrowness deliberately. A caller that needs `timed_shard_count` or
  # `machine_seconds` for a window of runs is still one `pick` per row and needs its own remedy.
  def preload_shard_counts(runs)
    return runs if runs.empty?

    counts = TestRunShard.where(test_run_id: runs.map(&:id)).group(:test_run_id).count
    runs.each { |run| run.preload_shard_count(counts[run.id]) }
  end
end
