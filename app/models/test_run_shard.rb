# frozen_string_literal: true

# One slice of a sharded run: what a single `POST /api/v1/ingest` contributed to its `TestRun`.
#
# These rows are the reason a re-run is not double-counted. The parent `TestRun`'s
# `total_specs_count` / `annotated_specs_count` are the SUM of its shards and its
# `duration_seconds` the MAX, recomputed by `Ingest::RunRecorder` after every ingest — so a shard
# reporting a second time overwrites its own row and the totals simply come out right, rather than
# the platform having to know whether it had seen that delivery before.
#
# `shard_id` is the client's name for the process within the run (`TEST_ENV_NUMBER`,
# `CI_NODE_INDEX`, `SPECGUARD_SHARD_ID`, …) and is unique per `TestRun` when present. It is
# nullable, and a nil is an *anonymous* slice: counted, but not recognisable on redelivery. See
# the migration and `Ingest::RunRecorder#upsert_shard` for what that costs.
#
# Only runs with a `ci_run_id` have these rows. An unnamed run — a laptop `bundle exec rspec` — is
# still one POST and one `TestRun` with nothing to fold, exactly as before.
class TestRunShard < ApplicationRecord
  belongs_to :test_run
  # The examples this delivery brought in. Deleting them is *not* declared here: the foreign key
  # is `ON DELETE SET NULL`, so a shard row going away leaves its observations attached to the run
  # they still belong to rather than taking them with it.
  has_many :spec_observations
end
