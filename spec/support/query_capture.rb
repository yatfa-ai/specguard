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
# TWO DELIBERATELY DIFFERENT PREDICATES live here, and they must not be folded together:
#
#   - `executed_sql` / `count_queries` drop `payload[:cached]` as well as `SCHEMA`/`TRANSACTION`:
#     a cached repeat costs no round trip, so it is not work the page chose to do. This is what a
#     budget on a PAGE or on a MODEL CALL counts.
#   - `queries_against(table)` drops only `SCHEMA`, so cached repeats and TRANSACTIONs are in its
#     count.
#
# The difference is not cosmetic: every expected count in the examples that call these was
# established under one rule or the other, so widening or narrowing either changes what a working
# example counts. `membership_reads` in spec/requests/repository_sharing_spec.rb spells out, for
# its own third rule, why a guard can positively need the cached repeats a page-budget drops. If a
# new example needs a rule that is neither of these, add it beside them with the same kind of note
# rather than bending one of them to fit.
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
end

RSpec.configure do |config|
  config.include QueryCapture
end
