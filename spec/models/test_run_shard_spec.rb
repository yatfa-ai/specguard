# frozen_string_literal: true

require "rails_helper"

RSpec.describe TestRunShard do
  let(:repository) { create_repository }
  let(:run) { repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-42") }

  def slice(shard_id:, total: 10, annotated: 4, duration: 60.0)
    { shard_id: shard_id, total_specs_count: total, annotated_specs_count: annotated,
      duration_seconds: duration }
  end

  # The database half of the shard-identity invariant, and the exact counterpart of
  # `spec/models/test_run_spec.rb`'s "the run identity" — written here because the two halves of
  # `Ingest::RunRecorder` protect the same shape sixty lines apart and only one of them was held.
  #
  # `#upsert_shard` reads a shard row before it writes one, but a lookup and an insert are two
  # statements and a retried job overlaps the original — the index is what makes the loser of that
  # race an exception to rescue rather than a second row splitting one slice's counts in two, and
  # the run's totals are a SUM over these rows, so a duplicate is not a cosmetic problem.
  describe "the shard identity" do
    it "refuses a second row for a shard this run has already recorded" do
      run.test_run_shards.create!(slice(shard_id: "1"))

      expect { run.test_run_shards.create!(slice(shard_id: "1")) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    # A shard index is only unique *within* a run — every run has a shard "1". Scoping the key to
    # the run is the reason `spec/requests/api/v1/ingest_spec.rb`'s "does not let one run's shard
    # overwrite another run's shard of the same name" is allowed to expect two rows rather than a
    # collision; without the scope, the second build's shard 1 could not be recorded at all.
    it "lets two runs each hold a shard of the same name" do
      other = repository.test_runs.create!(commit_sha: "deadbee", ci_run_id: "gha-43")
      run.test_run_shards.create!(slice(shard_id: "1"))

      expect { other.test_run_shards.create!(slice(shard_id: "1", total: 20, annotated: 9)) }
        .to change(TestRunShard, :count).by(1)
    end

    # The `WHERE shard_id IS NOT NULL` clause. A client that shards without exposing an index the
    # gem recognises sends nothing to tell its slices apart, so each POST *has* to become its own
    # row — `Ingest::RunRecorder#upsert_shard` says as much where it takes that branch. A
    # non-partial index would refuse the second anonymous slice outright and report a four-way
    # split as a quarter of the suite, which is the failure the counting exists to prevent.
    it "lets a run hold any number of slices the client did not name" do
      expect do
        3.times { run.test_run_shards.create!(slice(shard_id: nil)) }
      end.to change(TestRunShard, :count).by(3)
    end
  end
end
