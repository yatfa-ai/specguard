# frozen_string_literal: true

# One row per slice of a sharded run, so a slice that arrives twice can *replace* itself.
#
# `ci_run_id` alone was not enough, and the reason is that CI providers deliberately keep a build's
# id stable across a re-run (GitHub: `GITHUB_RUN_ID` *"does not change if you re-run the workflow
# run"*; Buildkite retries a job inside the same `BUILDKITE_BUILD_ID`; GitLab inside the same
# `CI_PIPELINE_ID`). With only a run id the platform could add an arriving slice but never
# recognise one, so pressing "re-run failed jobs" — the mainline recovery gesture for a sharded
# suite, since re-running all 20,000 examples for one flaky shard is the thing sharding exists to
# avoid — added the retried shard's counts *on top of* the ones it was replacing, and the headline
# ratio came out wrong rather than merely partial.
#
# Keyed by `(test_run_id, shard_id)`, the arithmetic stops being incremental: a `TestRun`'s counts
# are the SUM of its shards (and its `duration_seconds` the MAX), recomputed from these rows on
# every ingest. Re-running one shard, re-running all of them, or re-delivering the same shard N
# times all converge on the same numbers.
#
# == Why the unique index is partial, and what a NULL `shard_id` costs
#
# A client that shards without exposing an index the gem recognises sends `shard_id: nil`, and
# those slices genuinely cannot be told apart from one another. They are kept — losing a slice
# would be worse than counting it — and each gets its own row, which is what the partial `WHERE
# shard_id IS NOT NULL` is for. What they do not get is idempotency: an anonymous slice delivered
# twice is counted twice. That is stated here, in `Ingest::RunRecorder`, and in the client
# README's sharding section rather than left to be discovered from a wrong number.
class CreateTestRunShards < ActiveRecord::Migration[8.1]
  def change
    create_table :test_run_shards do |t|
      t.references :test_run, null: false, foreign_key: true
      t.string :shard_id
      t.integer :total_specs_count, null: false, default: 0
      t.integer :annotated_specs_count, null: false, default: 0
      t.float :duration_seconds

      t.timestamps
    end

    add_index :test_run_shards, %i[test_run_id shard_id],
              unique: true,
              where: "shard_id IS NOT NULL",
              name: "index_test_run_shards_on_test_run_id_and_shard_id"
  end
end
