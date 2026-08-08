# frozen_string_literal: true

# One row per example per run — the first thing SpecGuard stores that is *about a test* rather
# than about a suite.
#
# Before this table a 20,000-example run retained exactly two integers (`total_specs_count` and
# `annotated_specs_count`) plus one row per shard. The client has been sending nine fields per
# example since the formatter shipped; five of them — `id`, `spec_file_path`, `name`, `duration`,
# `outcome` — were read off the wire and dropped. Per-test duration, per-file growth and
# path-shaped navigation are all unanswerable against two integers, so this is where they land.
#
# == Why the key is `(test_run_id, example_id)` and not the coordinate
#
# `(file_path, line_number)` is the coordinate of the **code**, not of the **example**, and two
# ordinary suite shapes put several examples on one coordinate: a table-driven loop writes the
# `it` once, so all N examples report the same line; a shared example group reports the coordinate
# of `spec/support/shared.rb` and the file that actually ran the example appears nowhere.
# Measured by the client on a probe suite of a 3-case loop plus a 2-example shared group included
# by two files: **7 examples, 3 distinct coordinates**. A key that folds three examples onto one
# row cannot carry a per-example duration and hands any duplicate-cluster surface rows that look
# identical because the *key* collapsed them.
#
# So there is deliberately **no unique index on `(repository_id, file_path, line_number)`** here.
# `spec_intents` carries exactly that index and it is the collapsing key the client warns about;
# repeating it would reintroduce the defect one table over.
#
# `example_id` is RSpec's `Example#id` — `"./spec/foo_spec.rb[1:2]"`. The client states its scope
# precisely: *"`id` is unique within a run, not stable across refactors. `scoped_id` is
# positional, so reordering examples changes it … It is the run-local primary key and nothing
# more; matching one test across runs remains `name` plus file."* The unique index is therefore
# scoped to `test_run_id` and claims nothing beyond the run. There is **no column claiming durable
# cross-run identity** — that is a separate concern with its own unstarted prerequisite, and a
# column added now would guess at a shape that work has not settled.
#
# == Nullability, and why it is not laziness
#
# `duration_seconds` and `outcome` are `result&.run_time` and `result&.status&.to_s` on the client
# — the safe navigation is real, so both are nullable by construction rather than by permission.
# `name` is nullable **deliberately**: whether a spec carrying neither a name nor an annotation is
# a `400` is being decided elsewhere, and this column must not depend on which way that lands.
# `test_run_shard_id` is nullable because a run no CI provider named has no shard rows at all.
#
# `repository_id` is denormalised — every read worth having ("the slowest tests in this
# repository", "how did this file grow") is repository-scoped, and carrying the column removes a
# join from all of them. It is written explicitly by the recorder, since `insert_all` runs no
# callbacks and derives nothing.
class CreateSpecObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :spec_observations do |t|
      t.references :test_run, null: false, foreign_key: true
      t.references :repository, null: false, foreign_key: true
      # Nullable, and nulled rather than cascaded when a shard row goes: an observation belongs to
      # its run first and to the slice that delivered it second.
      t.references :test_run_shard, null: true, foreign_key: { on_delete: :nullify }
      t.string :example_id
      t.string :spec_file_path
      t.string :file_path, null: false
      t.integer :line_number, null: false
      t.text :name
      t.float :duration_seconds
      t.string :outcome
      t.string :status, null: false

      t.timestamps
    end

    # Run-local, exactly the scope the client claims for `id`.
    #
    # Not partial, and it does not need to be: Postgres treats NULLs as distinct in a unique
    # index, so a producer that sends no `id` at all still gets one row per example rather than
    # one row per run. Keeping it whole is also what lets `upsert_all(unique_by:)` name it as a
    # plain conflict target. The same NULL-distinctness is why an id-less producer gets no
    # redelivery protection from this index either — `Ingest::ObservationRecorder` documents that
    # as a known gap, since the only key that would close it is the coordinate above.
    add_index :spec_observations, %i[test_run_id example_id],
              unique: true,
              name: "index_spec_observations_on_test_run_id_and_example_id"

    # The three questions this table exists to answer, one index each: the slowest examples in a
    # run, the examples that failed in a run, and duration totalled by the file that *ran* the
    # example (`spec_file_path`, not `file_path` — which is what makes a shared example group
    # aggregate to the including file rather than to a `spec/support/` helper).
    add_index :spec_observations, %i[test_run_id duration_seconds]
    add_index :spec_observations, %i[test_run_id outcome]
    add_index :spec_observations, %i[test_run_id spec_file_path]
    # Repository-scoped rather than run-scoped on purpose: `name` is the durable half of the
    # client's own "matching one test across runs remains `name` plus file".
    add_index :spec_observations, %i[repository_id name]
  end
end
