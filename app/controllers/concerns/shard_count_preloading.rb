# frozen_string_literal: true

# Priming `TestRun#shard_count`, `#timed_shard_count` and `#machine_seconds` across a whole window
# of runs in ONE aggregate, for any surface that names how each of several runs was assembled —
# what coverage each of several runs' durations was measured over, or what each of them cost.
#
# Every route to those facts on the model — `TestRun#shard_count`, `#multi_shard?`,
# `#delivery_description`, `#machine_seconds_label` — goes through a memoized per-instance `pick`.
# Asked once per row, that is one query per row for one column, and it is the kind of N+1 that ships
# green: a query-budget example whose fixture holds one run, or none, cannot see it at all.
#
# The grouped aggregate runs on `index_test_run_shards_on_test_run_id` (db/schema.rb), keyed
# by the ids already loaded. A run with no shard rows — the whole unsharded corpus, every run that
# named no `ci_run_id` — is simply absent from the result and is primed with the zero
# `TestRun#delivery_description` already words as "reported in one piece", and with the nil machine
# time that means it reported no shard timing at all.
#
# Returns early on an empty list rather than letting `where(test_run_id: [])` issue a `WHERE 1=0`:
# a repository that has never ingested should pay nothing for a window of no rows.
#
# ONE MODULE, TWO BASES. This is included into both an `ActionController::Base` (the human Recent
# runs panel and the repositories grid) and an `ActionController::API` (the `history` block on
# `GET /api/v1/repository`). Nothing in the few lines below touches view helpers or anything an API
# controller lacks, so the differing bases were never an obstacle to sharing — which is why this is
# a module rather than the two verbatim copies it replaces.
module ShardCountPreloading
  extend ActiveSupport::Concern

  private

  # Primes THE TWO COUNTS AND THE MACHINE TIME, and never the rest of `shard_totals` —
  # `TestRun#preload_shard_count` documents that narrowness deliberately. The shards'
  # `MAX(updated_at)` is still one `pick` per row and still needs its own remedy.
  #
  # `COUNT(duration_seconds)` rides along as a second column of the aggregate the `GROUP BY` was
  # already computing, so the query budget is unchanged — two, not three, and the same two at one
  # row as at thirty (`spec/requests/api/v1/repository_latest_run_spec.rb` asserts exactly that).
  # It is here because `RepositoryOverview#serialized_history_row` serves a
  # `duration_seconds` that is a MAX over the shards that REPORTED: its denominator is the timed
  # count, and inferring it from `shard_count` is wrong on precisely the runs where a shard went
  # silent. That caller is the one this comment used to say "needs its own remedy".
  #
  # `SUM(duration_seconds)` is the THIRD column of that same statement, on the same argument and at
  # the same price: one round trip over `index_test_run_shards_on_test_run_id`, one row per run,
  # whatever the width of the SELECT list. Its caller is the repositories grid, which states what
  # each of N suites cost — and the MAX alone understates a sharded suite by 3.4× on the project's
  # canonical 4-shard fixture, so the affordable half could not be printed on its own. That retires
  # the second name this comment used to list as outstanding.
  #
  # `pluck` rather than `.group(:test_run_id).count`, which can only carry one aggregate. Each row
  # is primed through the three narrow seams separately, so no number can be handed another's
  # value.
  #
  # A run with no shard rows — the whole unsharded corpus — is simply absent from the result, and
  # the three seams disagree about what that absence MEANS, which is why they stay three. The
  # counts prime the really-counted `0` that `.to_i` yields, never a nil placeholder. The SUM primes
  # the `nil` through unchanged, because for it the absence is "no shard reported" and a `0` there
  # would be a measurement of zero seconds — a distinction `TestRun#machine_seconds_reported?`
  # exists to keep.
  def preload_shard_counts(runs)
    return runs if runs.empty?

    totals = TestRunShard.where(test_run_id: runs.map(&:id))
                         .group(:test_run_id)
                         .pluck(:test_run_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
                                Arel.sql("SUM(duration_seconds)"))
                         .to_h { |id, count, timed, machine| [id, [count, timed, machine]] }

    runs.each do |run|
      count, timed_count, machine_seconds = totals[run.id]
      run.preload_shard_count(count)
         .preload_timed_shard_count(timed_count)
         .preload_machine_seconds(machine_seconds)
    end
  end
end
