# frozen_string_literal: true

# Gives a run an identity of its own, so the N shards of one sharded CI run fold into one
# `TestRun` instead of landing as N rows with a split denominator.
#
# `commit_sha` cannot be that identity: a nightly and a later push of the same commit are
# genuinely two runs and must stay two rows. The client sources this from whatever its CI provider
# calls the build (`GITHUB_RUN_ID`, `CI_PIPELINE_ID`, …), which every shard of one run shares.
#
# These provider ids are documented as **stable across a re-run** of the same build — GitHub's
# `GITHUB_RUN_ID` is *"A unique number for each workflow run within a repository. This number does
# not change if you re-run the workflow run."* — and this column deliberately inherits that.
# "Re-run failed jobs" re-runs a *subset* of shards, and those need to land back on the run they
# came from rather than forming a new run holding only the shards that were retried. What makes
# that safe is `test_run_shards`: a shard replaces its own slice instead of adding to it. Neither
# table is correct without the other.
#
# == Why the unique index must be PARTIAL
#
# `ci_run_id` is nil for every run that no CI provider named — a laptop `bundle exec rspec`, a
# hand-rolled container, any provider not on the client's key list. In Postgres a plain unique
# index treats NULLs as distinct, so those rows would in fact still coexist; the `WHERE` clause is
# here anyway because it states the rule the application depends on rather than relying on a NULL
# comparison subtlety, and because it keeps the index off the rows that can never match a lookup.
# The local path is explicitly protected by the roadmap's DoD: an unnamed run always gets its own
# row, exactly as before.
#
# Nullable and **not** backfilled: every existing row predates the concept, and inventing an
# identity for a historical run would merge rows that were never one run.
class AddCiRunIdToTestRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :test_runs, :ci_run_id, :string

    add_index :test_runs, %i[repository_id ci_run_id],
              unique: true,
              where: "ci_run_id IS NOT NULL",
              name: "index_test_runs_on_repository_id_and_ci_run_id"
  end
end
