# The SQL a block issues — every statement, or every one against a single table — so an N+1 shows
# up as N queries rather than as a passing test.
#
# Here rather than beside the examples that use it, because the same subscriber is needed at two
# levels of the same guard: the request spec bounds what a PAGE asks across a window of rows, and
# the model spec bounds what ONE primed row asks. Two hand-rolled copies of the same subscriber
# would be free to drift in what they filter — the `"SCHEMA"` exclusion in particular, without
# which every example is at the mercy of whether the connection had already loaded the table's
# columns — and a guard that silently counts one query more or less than its sibling is worse than
# no guard, because it still reports a number.
#
# The `ensure` is load-bearing: an unsubscribed-from subscriber outlives the example and counts
# queries for the rest of the suite.
#
# THREE DELIBERATELY DIFFERENT PREDICATES live here, and they must not be folded together:
#
#   - `executed_sql` / `count_queries` drop `payload[:cached]` as well as `SCHEMA`/`TRANSACTION`:
#     a cached repeat costs no round trip, so it is not work the page chose to do. This is what a
#     budget on a PAGE or on a MODEL CALL counts.
#   - `queries_against(table)` drops only `SCHEMA`, so cached repeats and TRANSACTIONs are in its
#     count.
#   - `captured_sql(table)` drops only `SCHEMA` like `queries_against`, but keeps the FIRST match
#     rather than a list and runs under `unprepared_statement`; it counts nothing, it captures a
#     statement to be planned.
#
# The difference is not cosmetic: every expected count in the examples that call the two counting
# rules was established under one or the other, so widening or narrowing either changes what a
# working example counts. `captured_sql` establishes no counts at all — it is a third predicate
# because of what it FILTERS and what it KEEPS, not because anything totals it, so the caution
# above about widening a count does not reach it. `membership_reads` in
# spec/requests/repository_sharing_spec.rb spells out, for its own third rule, why a guard can
# positively need the cached repeats a page-budget drops. If a new example needs a rule that is
# none of these, add it beside them with the same kind of note rather than bending one of them to
# fit.
module QueryCapture
  def queries_against(table)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      queries << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].to_s.include?(table)
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # Every statement a block issues that the page or the call actually paid a round trip for.
  def executed_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      statements << payload[:sql].to_s unless payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # One rule, two readings, so a change to what counts as a query cannot drift between them.
  def count_queries(&) = executed_sql(&).size

  # A THIRD PREDICATE, and it is neither of the two above: it keeps the FIRST matching statement
  # rather than a list, and it runs the block under `unprepared_statement` so the captured SQL
  # carries its literals — `EXPLAIN` cannot be handed a `$1`. Nothing here counts anything; the
  # statement is captured in order to be planned.
  #
  # Captured off the wire rather than EXPLAINed from a hand-written copy of the query: a copy is a
  # second definition of the read, free to drift from the one the code actually makes. This is what
  # a read whose projection is not on the relation — a `pluck` of aggregates, with no `to_sql`
  # worth EXPLAINing — has to use.
  #
  # `table` is passed rather than defaulted for the same reason `queries_against(table)` takes one:
  # a default here would be one caller's table baked into a globally-included support file.
  def captured_sql(table, &)
    captured = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      captured ||= payload[:sql] if payload[:name] != "SCHEMA" &&
                                    payload[:sql].to_s.include?(table)
    end
    ActiveRecord::Base.connection.unprepared_statement(&)

    captured
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def plan_for_actual_sql(table, &)
    ActiveRecord::Base.connection.select_values("EXPLAIN #{captured_sql(table, &)}").join("\n")
  end

  # How many rows of `table` the read ACTUALLY touched, off `EXPLAIN (ANALYZE)` — the only spelling
  # of this assertion that measures the query rather than restating the SQL. Rows removed by a
  # filter are counted too: a plan that reached ten times as many rows and threw them away has not
  # been bounded, whatever it returned.
  #
  # Only nodes carrying a `Relation Name` are counted, so a bitmap's index node and its heap node
  # are not the same rows twice — the index node names an index and no relation.
  def rows_touched(table, &)
    plan = ActiveRecord::Base.connection.select_value(
      "EXPLAIN (ANALYZE, FORMAT JSON) #{captured_sql(table, &)}"
    )
    plan = JSON.parse(plan) if plan.is_a?(String)

    total = 0
    walk = lambda do |node|
      if node["Relation Name"] == table
        total += (node["Actual Rows"].to_i + node["Rows Removed by Filter"].to_i) *
                 [node["Actual Loops"].to_i, 1].max
      end
      Array(node["Plans"]).each { |child| walk.call(child) }
    end
    walk.call(plan.first["Plan"])

    total
  end
end

RSpec.configure do |config|
  config.include QueryCapture
end
