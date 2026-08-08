# frozen_string_literal: true

# One example, in one run. The grain everything the product promises about *tests* — rather than
# about suites — has to be asked at.
#
# A run's headline counters (`TestRun#total_specs_count`, `#annotated_specs_count`) are two
# integers derived from `test_run_shards`, and they stay that way: nothing here re-derives them.
# These rows answer the questions those integers cannot — which examples were slow, which failed,
# how much of the wall clock a given spec file spent — for **one run**. They are per-run facts,
# not a history: "the slowest tests in this run" is a question this table answers with a single
# indexed query; "the slowest tests in this repository" spans runs and belongs to the work that
# settles cross-run identity.
#
# == The key is run-local, and says so
#
# `example_id` is RSpec's `Example#id` (`"./spec/orders_spec.rb[1:2]"`), unique within a run and
# explicitly *not* stable across refactors — `scoped_id` is positional, so reordering examples
# changes it. Uniqueness is `(test_run_id, example_id)` and nothing wider. Deliberately absent:
# any unique index on `(repository_id, file_path, line_number)`. That coordinate identifies the
# *code*, and a table-driven loop or a shared example group puts many examples on one — the
# client measured 7 examples across 3 distinct coordinates on a small probe suite. Collapsing
# those would destroy exactly the grain this table exists to hold.
#
# == Two paths, two meanings
#
# `file_path` / `line_number` are the **definition site**: the line the annotation was read from,
# unchanged in meaning from `spec_intents`. `spec_file_path` is RSpec's `rerun_file_path` — the
# **including** file, equal to `file_path` for an ordinary example and different only for a shared
# example group. Aggregate duration by `spec_file_path`, so a shared group's time lands on the
# file that ran it rather than on a `spec/support/` helper.
class SpecObservation < ApplicationRecord
  belongs_to :test_run
  belongs_to :repository
  # Which delivery brought this row in. Null for a run no CI provider named — those runs have no
  # shard rows at all — and null again if the shard row is later deleted; the observation belongs
  # to its run first.
  belongs_to :test_run_shard, optional: true
end
