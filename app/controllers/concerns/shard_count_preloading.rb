# frozen_string_literal: true

# Priming `TestRun#shard_count` and `#timed_shard_count` across a whole window of runs in ONE
# aggregate, for any surface that names how each of several runs was assembled — or what coverage
# each of several runs' durations was measured over.
#
# Every route to that fact on the model — `TestRun#shard_count`, `#multi_shard?`,
# `#delivery_description` — goes through a memoized per-instance `pick`. Asked once per row, that
# is one query per row for one column, and it is the kind of N+1 that ships green: a query-budget
# example whose fixture holds one run, or none, cannot see it at all.
#
# The grouped aggregate runs on `index_test_run_shards_on_test_run_id` (db/schema.rb), keyed
# by the ids already loaded. A run with no shard rows — the whole unsharded corpus, every run that
# named no `ci_run_id` — is simply absent from the result and is primed with the zero
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

  # Primes THE TWO COUNTS and never the rest of `shard_totals` — `TestRun#preload_shard_count`
  # documents that narrowness deliberately. `machine_seconds` and the shards' `MAX(updated_at)` are
  # still one `pick` per row and still need their own remedy.
  #
  # `COUNT(duration_seconds)` rides along as a second column of the aggregate the `GROUP BY` was
  # already computing, so the query budget is unchanged — two, not three, and the same two at one
  # row as at thirty (`spec/requests/api/v1/repository_latest_run_spec.rb` asserts exactly that).
  # It is here because `Api::V1::RepositoriesController#serialized_history_row` serves a
  # `duration_seconds` that is a MAX over the shards that REPORTED: its denominator is the timed
  # count, and inferring it from `shard_count` is wrong on precisely the runs where a shard went
  # silent. That caller is the one this comment used to say "needs its own remedy".
  #
  # `pluck` rather than `.group(:test_run_id).count`, which can only carry one aggregate. Each row
  # is primed through the two narrow seams separately, so neither number can be handed the other's
  # value.
  #
  # Both are `nil` for a run with no shard rows — the whole unsharded corpus is simply absent from
  # the result — and both prime the really-counted `0` that `.to_i` yields, never a nil placeholder.
  def preload_shard_counts(runs)
    return runs if runs.empty?

    counts = TestRunShard.where(test_run_id: runs.map(&:id))
                         .group(:test_run_id)
                         .pluck(:test_run_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"))
                         .to_h { |id, count, timed_count| [id, [count, timed_count]] }

    runs.each do |run|
      count, timed_count = counts[run.id]
      run.preload_shard_count(count).preload_timed_shard_count(timed_count)
    end
  end
end
