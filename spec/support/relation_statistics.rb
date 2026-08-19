# frozen_string_literal: true

# Restores the relation statistics an `ANALYZE` inside a transactional example leaves behind.
#
# `ANALYZE` is legal inside the transaction the suite wraps each example in — and it is *not*
# contained by it. It writes to two places, and only one of them is transactional:
#
#   * `pg_statistic` — the histograms and most-common-value lists. Written transactionally, so a
#     rolled back example does take these with it.
#   * `pg_class.reltuples` / `relpages` — the row-count and size estimates, for the table AND for
#     every index on it. Written by `vac_update_relstats()` through `heap_inplace_update()`, a
#     non-transactional in-place catalog write. **These survive the rollback.** They are on-disk
#     catalog state, so they outlive the example, the process and the run, until something
#     re-analyzes.
#
# `reltuples` is a primary driver of plan choice. So a big-seed example that analyzes leaves the
# catalog claiming a cardinality the table has not had since its own rollback, and every
# plan-asserting example that runs afterwards plans against that phantom.
#
# Measured on PostgreSQL 17, running `spec/models/near_duplicate_clusters_spec.rb` alone against a
# freshly prepared test database (SPGD-731). Rows before and after: 0 and 0.
#
#     spec_identities                     reltuples    -1 ->  6500    relpages  0 ->  1138
#     spec_observations                   reltuples    -1 ->  3000    relpages  0 ->   406
#     index_spec_identities_on_embedding  reltuples     0 ->  6500    relpages  2 -> 11902
#     spec_identities_pkey                reltuples     0 ->  6500    relpages  1 ->   127
#     ...and every other index on both tables, in the same direction.
#
# The indexes are the half that is easy to miss and expensive to leave: a plan assertion of the
# form "Index Scan using ..." is decided by exactly these numbers.
#
# The thing that survives the rollback does not survive forever — autovacuum eventually re-derives
# it from the (now empty) table. Measured here, that took somewhere between 0 and 10 seconds. That
# is what makes the resulting failures intermittent rather than reproducible: the poisoned window
# is real, but its width is set by autovacuum's asynchronous schedule rather than by anything in
# the suite. An example is only affected if it happens to run inside the window.
#
# Usage — declare it on the example group whose seeding `before` runs the `ANALYZE`:
#
#     describe "what it costs at scale" do
#       restores_relation_statistics_for "spec_identities", "spec_observations"
#
#       before { ...seed...; connection.execute("ANALYZE spec_identities") }
#     end
#
# The `ANALYZE` keeps working normally inside the example; this only puts the catalog back
# afterwards. Snapshot and restore run in `before(:context)` / `after(:context)`, which are OUTSIDE
# the per-example transaction (`open_transactions` is 0 in both, and 1 inside an example). That
# placement is load-bearing: a plain `UPDATE pg_class` is an ordinary transactional catalog write,
# so the same restore run from an `after` (`:each`) hook would be rolled back with the example and
# silently put nothing back.
module RelationStatistics
  module_function

  # The relation's own catalog row plus one per index on it — the full set `ANALYZE` updates.
  def snapshot(relations)
    Array(relations).flat_map do |relation|
      quoted = ActiveRecord::Base.connection.quote(relation.to_s)

      ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
        SELECT c.oid, c.relname, c.reltuples, c.relpages
        FROM pg_class c
        WHERE c.oid = #{quoted}::regclass
           OR c.oid IN (SELECT i.indexrelid FROM pg_index i WHERE i.indrelid = #{quoted}::regclass)
      SQL
    end
  end

  # Writes the snapshotted values back by oid. Restoring `relpages` matters as much as `reltuples`:
  # the dead pages a rolled back seed leaves behind are still charged to a later scan's cost.
  def restore(rows)
    Array(rows).each do |row|
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        UPDATE pg_class
        SET reltuples = #{row["reltuples"].to_f}, relpages = #{row["relpages"].to_i}
        WHERE oid = #{row["oid"].to_i}
      SQL
    end
  end

  module ExampleGroup
    def restores_relation_statistics_for(*relations)
      snapshot = nil

      before(:context) { snapshot = RelationStatistics.snapshot(relations) }
      after(:context) { RelationStatistics.restore(snapshot) }
    end
  end
end

RSpec.configure do |config|
  config.extend RelationStatistics::ExampleGroup
end
