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
#
# ## The capability precondition (SPGD-959)
#
# Everything above *assumes* the connected role is allowed to write `pg_class`. That assumption
# holds on CI (superuser `postgres` on pg16) and is FALSE in the agent sandbox, whose test
# databases are owned by a non-superuser role: `snapshot` (a SELECT; PUBLIC-granted) succeeds in
# `before(:context)`, `restore` raises `PG::InsufficientPrivilege` in `after(:context)` — 8 hook
# errors on a clean tree, and with the restore gone, the leak above lands on every later group.
# The precondition is now probed instead of assumed, and the best available route wins:
#
#   1. `:catalog_write` — the role may `UPDATE pg_class`. Today's restore, byte for byte. This is
#      CI. Probing UPDATE first is deliberate: an environment that is green today never changes
#      behaviour, because this tier wins whenever it is available.
#   2. `:restore_api` — the role may not touch `pg_class`, but PostgreSQL 18's supported
#      `pg_restore_relation_stats()` is present, EXECUTE-granted, and the role holds `MAINTAIN` on
#      every snapshotted relation *and every index on it*. Measured on PG18.4 as the owning
#      non-superuser role: this restores for real, by schema+name (hence `schemaname` in the
#      snapshot), indexes included, and it can write `reltuples = -1`, so the never-analyzed
#      fingerprint survives on this route too.
#   3. `:none` — neither route is available. Restore is impossible, so from `before(:context)` the
#      whole declaring group is skipped loudly (one warning per process) rather than allowed to
#      `ANALYZE` and leak. A group skipped this way runs zero examples and zero seeding hooks.
#
# The two environment-wide facts (`UPDATE` on `pg_class`; the function's existence and EXECUTE
# grant) are resolved once per process and memoized — they cannot change mid-run. `MAINTAIN` is
# evaluated per group over that group's actual snapshot rows (one cheap query per declaring group)
# so an unmaintained relation degrades its own group rather than inheriting whatever the first
# group happened to probe. ⚠ Do NOT infer capability from `pg_restore_relation_stats()`'s boolean
# return or from a lack of raise: on PG18.4 that call *succeeds silently* even on relations the
# role does not own (verified against `pg_catalog.pg_class`), which is exactly why the probe runs
# up front and the restore is never wrapped in a rescue.
module RelationStatistics
  module_function

  # The relation's own catalog row plus one per index on it — the full set `ANALYZE` updates.
  # `schemaname` rides along because tier 2 addresses relations by schema+name, not by oid.
  def snapshot(relations)
    Array(relations).flat_map do |relation|
      quoted = ActiveRecord::Base.connection.quote(relation.to_s)

      ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
        SELECT c.oid, n.nspname AS schemaname, c.relname, c.reltuples, c.relpages
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.oid = #{quoted}::regclass
           OR c.oid IN (SELECT i.indexrelid FROM pg_index i WHERE i.indrelid = #{quoted}::regclass)
      SQL
    end
  end

  # Writes the snapshotted values back by oid. Restoring `relpages` matters as much as `reltuples`:
  # the dead pages a rolled back seed leaves behind are still charged to a later scan's cost.
  def restore(rows)
    rows = Array(rows)
    return if rows.empty?

    case capability_for(rows)
    when :catalog_write then restore_via_catalog_write(rows)
    when :restore_api then restore_via_supported_api(rows)
    # :none — restore is impossible. The declaring group was already skipped in
    # before(:context), so this is only reachable if a group is faked past its
    # own probe; touch nothing rather than half-write.
    end
  end

  # The restore route available for these rows: `:catalog_write`, `:restore_api`, or `:none`.
  def capability_for(rows)
    return :catalog_write if catalog_writable?
    return :restore_api if restore_api_available? && maintains_all?(rows)

    :none
  end

  def catalog_writable?
    @catalog_writable = probe_catalog_write if @catalog_writable.nil?
    @catalog_writable
  end

  def restore_api_available?
    @restore_api_available = probe_restore_api if @restore_api_available.nil?
    @restore_api_available
  end

  def maintains_all?(rows)
    return true if rows.empty?

    oids = rows.map { |row| row["oid"].to_i }.join(", ")
    grants = ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
      SELECT c.oid, has_table_privilege(current_user, c.oid, 'MAINTAIN') AS maintainable
      FROM pg_class c
      WHERE c.oid IN (#{oids})
    SQL

    grants.all? { |row| row["maintainable"] == true || row["maintainable"] == "t" }
  end

  # Tier 3's loud exit: warns ONCE per process (the first declaring group to hit it), then hands
  # back the message RSpec attaches to every example of the skipped group.
  def unavailable_message(rows)
    unless @warned_unavailable
      @warned_unavailable = true
      message = <<~MSG.chomp
        RelationStatistics: database role '#{current_role}' can neither UPDATE pg_class nor use
        pg_restore_relation_stats() (missing: #{missing_capabilities(rows)}). ANALYZE-written
        catalog statistics cannot be restored, so every example group declaring
        restores_relation_statistics_for is SKIPPED rather than allowed to leave the leak behind
        for later plan-asserting examples. (SPGD-959; one warning per process.)
      MSG
      warn message
    end

    "relation statistics unrestorable as role '#{current_role}' " \
      "(missing: #{missing_capabilities(rows)}); group skipped"
  end

  def missing_capabilities(rows)
    missing = []
    missing << "UPDATE on pg_class" unless catalog_writable?
    if restore_api_available?
      missing << "MAINTAIN on #{rows.length} snapshotted relation(s)" unless maintains_all?(rows)
    else
      missing << "EXECUTE on pg_restore_relation_stats()"
    end
    missing.join(" and ")
  end

  def current_role
    @current_role ||= ActiveRecord::Base.connection.select_value("SELECT current_user")
  end

  # Version-agnostic on purpose: `to_regprocedure('pg_restore_relation_stats(variadic "any")')`
  # is a syntax error, and pinning a version-specific signature would lie on the sibling server.
  def probe_restore_api
    ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'pg_restore_relation_stats'
          AND has_function_privilege(current_user, oid, 'EXECUTE')
      )
    SQL
  end

  def probe_catalog_write
    ActiveRecord::Base.connection.select_value(
      "SELECT has_table_privilege(current_user, 'pg_class', 'UPDATE')"
    )
  end

  # Tier 1 — today's restore, untouched. Addressed by oid, exactly as shipped.
  def restore_via_catalog_write(rows)
    Array(rows).each do |row|
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        UPDATE pg_class
        SET reltuples = #{row["reltuples"].to_f}, relpages = #{row["relpages"].to_i}
        WHERE oid = #{row["oid"].to_i}
      SQL
    end
  end

  # Tier 2 — the supported PG18 route. Addressed by schema+name (its required arguments); flat
  # alternating name/value pairs because the signature is `VARIADIC kwargs "any"`. The boolean
  # return is deliberately ignored: it is not a capability signal (see the header), and anything
  # that can actually fail here raises on its own.
  def restore_via_supported_api(rows)
    connection = ActiveRecord::Base.connection
    Array(rows).each do |row|
      connection.execute(<<~SQL.squish)
        SELECT pg_restore_relation_stats(
          'schemaname'::text, #{connection.quote(row["schemaname"])},
          'relname'::text, #{connection.quote(row["relname"])},
          'reltuples'::text, #{row["reltuples"].to_f}::real,
          'relpages'::text, #{row["relpages"].to_i}::integer)
      SQL
    end
  end

  module ExampleGroup
    def restores_relation_statistics_for(*relations)
      snapshot = nil

      before(:context) do
        snapshot = RelationStatistics.snapshot(relations)

        if RelationStatistics.capability_for(snapshot) == :none
          skip RelationStatistics.unavailable_message(snapshot)
        end
      end
      after(:context) { RelationStatistics.restore(snapshot) }
    end
  end
end

RSpec.configure do |config|
  config.extend RelationStatistics::ExampleGroup
end
