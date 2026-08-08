# Every SELECT a block issues against one table, so an N+1 shows up as N queries rather than as a
# passing test.
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
end

RSpec.configure do |config|
  config.include QueryCapture
end
