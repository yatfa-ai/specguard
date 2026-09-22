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
#     count. Its argument is a String matched as a SUBSTRING, or a Regexp matched against the
#     statement — see the note on the method itself for why the second spelling exists and why
#     adding it changed no existing count.
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
#
# `rows_touched` and `plan_for_actual_sql` are not one of those rules and total nothing on the
# wire: both plan the statement `captured_sql` caught — one to sum the rows the plan says were
# touched, one to hand back the plan Postgres chose.
#
# BOTH carry failure evidence at the foot of this file, and the two legs surface different halves
# of a reddening:
#
#   - `rows_touched` fails as a naked number comparison, so its leg surfaces the PLAN it already
#     fetched — the access method and the per-node actual rows.
#   - `plan_for_actual_sql` fails with the plan itself already in the matcher's `got`, so its leg
#     surfaces what the plan output does not show: the catalog statistics — `pg_class.reltuples` /
#     `relpages` for the captured table and every index on it — that decided the choice. Those are
#     exactly the numbers `restores_relation_statistics_for` exists because `ANALYZE` perturbs
#     them, and the same leg spec/support/near_duplicate_failure_evidence.rb collects for the HNSW
#     family; this one is for the plan-asserting family in spec/models/spec_observation_spec.rb,
#     whose reddening has been misattributed at three separate seats in ~15 days while the stats
#     that explained the plan sat unread in the catalog. (SPGD-1351.)
#
# The evidence sections say why these are hooks rather than the rescue the HNSW sibling uses.
module QueryCapture
  # `table` is a String (matched as a substring, the original and still the common spelling) or a
  # Regexp (matched against the statement). The Regexp spelling exists because a table is not always
  # the right POPULATION: a guard on what AUTHENTICATION costs has to see the credential table and
  # `users` together, since the two failure modes it watches for — probing the second credential
  # table, and reading the resolved person a second time — land on different tables and a filter
  # naming either one alone reports a clean count while the other regresses. See
  # `authentication_reads` in spec/requests/api/v1/credential_seam_spec.rb.
  #
  # This WIDENS what can be matched, not what is COUNTED: the `SCHEMA`-only exclusion above is
  # untouched, and every String caller matches exactly the statements it matched before. So the
  # header's caution about established counts is not in play here — no existing expectation moves.
  def queries_against(table)
    matches = table.is_a?(Regexp) ? ->(sql) { table.match?(sql) } : ->(sql) { sql.include?(table) }

    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      queries << payload[:sql] if payload[:name] != "SCHEMA" && matches.call(payload[:sql].to_s)
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

  # The snapshot is taken at CAPTURE time and retained beside the plan, not re-read on the failure
  # path — see the relation-statistics evidence section below for why that ordering is deliberate
  # and what it costs.
  def plan_for_actual_sql(table, &)
    sql = captured_sql(table, &)
    retain_plan_relation_statistics(table, RelationStatistics.snapshot(table))
    ActiveRecord::Base.connection.select_values("EXPLAIN #{sql}").join("\n")
  end

  # How many rows of `table` the read ACTUALLY touched, off `EXPLAIN (ANALYZE)` — the only spelling
  # of this assertion that measures the query rather than restating the SQL. Rows removed by a
  # filter are counted too: a plan that reached ten times as many rows and threw them away has not
  # been bounded, whatever it returned.
  #
  # Only nodes carrying a `Relation Name` are counted, so a bitmap's index node and its heap node
  # are not the same rows twice — the index node names an index and no relation.
  #
  # The parsed plan is RETAINED on the example before it is walked — see the evidence section
  # below for what that buys and why it costs no query.
  def rows_touched(table, &)
    plan = ActiveRecord::Base.connection.select_value(
      "EXPLAIN (ANALYZE, FORMAT JSON) #{captured_sql(table, &)}"
    )
    plan = JSON.parse(plan) if plan.is_a?(String)
    retain_rows_touched_plan(table, plan)

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

  # ─────────────────────────── `rows_touched` failure evidence ───────────────────────────
  #
  # `rows_touched` returns an Integer, so every bound built on it fails as a naked number
  # comparison — an expected ceiling and a got value, and nothing else — with no plan, no access
  # method and no per-node actual rows, and therefore no indication of WHY the bound was exceeded.
  # The plan that answers it was parsed microseconds earlier in the very same method and then
  # dropped on the floor.
  # These bounds are documented as plan-sensitive (the groups that hold them declare
  # `restores_relation_statistics_for` precisely because `ANALYZE`-written `pg_class.reltuples`
  # survives a rollback and moves plan choice, and the sibling access-method matcher in
  # spec/models/spec_observation_spec.rb was widened after exactly that happened), so the agent
  # adjudicating a reddening needs the plan and has had to reconstruct it by hand.
  #
  # == WHY THIS IS A HOOK AND NOT A RESCUE — do not "fix" it back toward the HNSW shape
  #
  # spec/support/near_duplicate_failure_evidence.rb collects its evidence by RESCUING
  # `RSpec::Expectations::ExpectationNotMetError` and re-raising with the evidence appended. That
  # shape is STRUCTURALLY UNAVAILABLE here, and the reason is in the CALL SITES rather than in
  # this file: `rows_touched` has already RETURNED an Integer by the time the comparison is made,
  # and the comparison is made in the example body, outside any block this file controls. Nothing
  # raises inside `rows_touched`, so a `rescue` placed there would catch nothing. The HNSW
  # precedent works only because `evidencing_near_duplicate_failure` wraps the ASSERTIONS too —
  # its caller opted in by enclosing them. Adopting that shape here means editing the call sites,
  # and the whole point of this helper is that they keep reading as a bare numeric bound.
  #
  # So the plan is retained on per-example state and appended to the RENDERED failure from an
  # `after` hook via RSpec's `Example#display_exception=`. That alters only what is displayed, not
  # pass/fail status — `set_exception` would be the wrong verb, since it ADDS a failure.
  #
  # == What this does NOT reach, stated rather than left to be discovered
  #
  # An example carrying `:aggregate_failures` METADATA has a nil `example.exception` in every
  # `after` hook: rspec-core's own built-in `around` hook calls `set_aggregate_failures_exception`
  # only after the example's hooks have run, so there is no hook from which that shape is
  # reachable. An `aggregate_failures` block written INSIDE an example body is reached normally,
  # and takes the branch below that appends to the aggregate rather than rewriting it.
  #
  # == The green path pays nothing
  #
  # Retention is one array push over a plan `rows_touched` had already parsed, and rendering
  # happens only when an example both retained a plan and failed. Rendering issues NO query — it
  # walks the retained structure — so the EXPLAIN a green example pays for is still exactly the
  # one `rows_touched` itself made.
  ROWS_TOUCHED_EVIDENCE_HEADER = "──── rows_touched plan evidence (SPGD-1344) ────"

  # Carries the evidence into an aggregate's sub-failure list. Named for what it holds, because
  # that name is what the reader sees rendered beside the bound that broke.
  class RetainedPlan < StandardError; end

  # The plans this example retained, in invocation order. A call site may invoke `rows_touched`
  # more than once against the same table, and the failure names ONE number, so order and table
  # are what let a reader tell which invocation produced it. Empty — and the hook therefore a
  # no-op — for every example that never called `rows_touched`.
  def retained_rows_touched_plans
    @retained_rows_touched_plans ||= []
  end

  def retain_rows_touched_plan(table, plan)
    retained_rows_touched_plans << { table: table.to_s, plan: plan }
  end

  def discard_retained_rows_touched_plans
    @retained_rows_touched_plans = nil
  end

  # The evidence block, formatted. ISSUES NO QUERY: every datum here was already in hand.
  def rows_touched_plan_evidence
    lines = [
      ROWS_TOUCHED_EVIDENCE_HEADER,
      "Retained by rows_touched from the EXPLAIN (ANALYZE) it had already run for this example; " \
      "rendering it issued no query. Each retained plan is labelled by the table it was taken " \
      "against and by the order it was invoked in, because a bound names one number and an " \
      "example may invoke the helper more than once."
    ]

    retained_rows_touched_plans.each_with_index do |retained, index|
      lines << "── rows_touched(#{retained[:table].inspect}), invocation #{index + 1} ──"
      lines.concat(rows_touched_plan_lines(retained[:plan]))
    end

    lines << "──────────────────────────────────────────────────"
    lines.join("\n")
  end

  # The parsed plan as a readable tree rather than one unbroken JSON line: the access method, the
  # relation or index it names, and the per-node actual rows are what the bound is adjudicated on.
  def rows_touched_plan_lines(plan)
    root = Array(plan).first || {}
    lines = rows_touched_plan_node_lines(root["Plan"] || {})
    timings = ["Planning Time", "Execution Time"].filter_map do |key|
      "#{key}: #{root[key]}" if root.key?(key)
    end
    lines << "  #{timings.join('  ')}" unless timings.empty?
    lines
  end

  def rows_touched_plan_node_lines(node, depth = 0)
    indent = "  " * (depth + 1)

    heading = [node["Node Type"]]
    heading << "using #{node['Index Name']}" if node["Index Name"]
    heading << "on #{node['Relation Name']}" if node["Relation Name"]

    measured = ["Actual Rows", "Actual Loops", "Rows Removed by Filter"].filter_map do |key|
      "#{key.downcase}=#{node[key]}" if node.key?(key)
    end
    heading << "(#{measured.join(', ')})" unless measured.empty?

    lines = ["#{indent}#{heading.join(' ')}"]
    ["Index Cond", "Filter"].each do |key|
      lines << "#{indent}  #{key}: #{node[key]}" if node[key]
    end
    Array(node["Plans"]).each do |child|
      lines.concat(rows_touched_plan_node_lines(child, depth + 1))
    end
    lines
  end

  # Appends the retained plans to what the reader will SEE for a failing example, leaving the
  # original failure's class, backtrace and message text untouched above it.
  #
  # The ORIGINAL FAILURE ALWAYS WINS: if rendering the evidence blows up, say so inline rather
  # than replacing the bound's own message with a collector stack trace — the same fallback
  # `with_appended_near_duplicate_evidence` makes.
  #
  # The `ensure` is belt-and-braces rather than the thing that keeps a plan out of a later
  # example's failure: RSpec builds a FRESH example-group instance per example, so the ivar these
  # plans live on is already per-example and a probe that removed this line left the isolation
  # green. It is kept because the state is read from a hook rather than from the body that wrote
  # it — the same caution this file's header states for the subscribers, whose `ensure` IS
  # load-bearing because a subscriber is process-global and genuinely outlives the example.
  def append_rows_touched_plan_evidence(example)
    return if retained_rows_touched_plans.empty?

    failure = example.exception
    return if failure.nil?

    evidence =
      begin
        rows_touched_plan_evidence
      rescue StandardError => e
        "#{ROWS_TOUCHED_EVIDENCE_HEADER}\ncould not be collected (#{e.class}: #{e.message})"
      end

    if defined?(RSpec::Core::MultipleExceptionError::InterfaceTag) &&
       RSpec::Core::MultipleExceptionError::InterfaceTag === failure
      # An aggregate is a LIST of failures; appending to its message would bury the evidence above
      # entries it does not belong to. It takes an entry of its own instead.
      note = RetainedPlan.new(evidence)
      note.set_backtrace([])
      failure.add(note)
    else
      # Duplicated and re-messaged rather than reconstructed with `original.class.new(...)` — the
      # spelling near_duplicate_failure_evidence.rb uses — because this path never chooses the
      # class it is handed: a dup carries the original's class, backtrace and every other
      # attribute across for free, and cannot fail on an exception whose constructor takes
      # something other than a message.
      enriched = failure.dup
      message = "#{failure.message}\n#{evidence}"
      enriched.define_singleton_method(:message) { message }
      enriched.define_singleton_method(:to_s) { message }
      example.display_exception = enriched
    end
  ensure
    discard_retained_rows_touched_plans
  end

  # ─────────────────── the plan helpers' relation-statistics evidence ───────────────────
  #
  # "Helpers", plural, because more than one joins: `plan_for_actual_sql` (below, SPGD-1351) and
  # the file-local `plan_for` relations the plan-asserting spec files define (SPGD-1381). Each
  # retaining call site names itself through `source:`, so a rendered snapshot says WHICH helper
  # took it.
  #
  # A plan assertion fails with the plan already visible — it is the matcher's `got` — so what the
  # reader of the red is missing is not the plan but the WHY: `pg_class.reltuples`/`relpages` for
  # the captured table and every index on it, the numbers that decided the access method. These
  # are the same numbers `restores_relation_statistics_for` manages, because `ANALYZE`-written
  # `pg_class` rows survive the example's rollback and move plan choice — and the drill-down
  # example this evidence serves has been misattributed at three separate seats in ~15 days while
  # the explaining numbers sat unread in the catalog (a physically larger competing index beside a
  # logically clean catalog is exactly the state that flips plan choice and reads as a phantom
  # regression).
  #
  # == The snapshot is taken at CAPTURE time, and that ordering is deliberate
  #
  # Not a failure-path re-read: by the time the evidence hook runs, the declaring group's restore
  # machinery and autovacuum are both free to have rewritten `pg_class` — the support file
  # documents autovacuum re-deriving the numbers within 0-10 seconds of a rollback. A snapshot
  # taken at the same instant the EXPLAIN was produced — while the example transaction is open and
  # the perturbed catalog state is live — is immune to that ordering by construction: it is the
  # state the planner actually acted on. The cost is one extra catalog SELECT per retaining
  # invocation, on the success path too — spec-only, plan-asserting examples only. (If that cost is
  # ever objected to, the fallback is retaining the table and reading stats on the failure path —
  # but that variant re-introduces the ordering question above and must be tested against the
  # declaring group's restore; do not make that trade silently.)
  #
  # == Why this is a sibling HOOK and how the two legs compose
  #
  # The same reason `append_rows_touched_plan_evidence` is a hook rather than a rescue — the
  # helper has already RETURNED the plan by the time the assertion is made, so a `rescue` here
  # would catch nothing; that section carries the full argument. It is a sibling hook rather than
  # a branch of the existing one so each leg stays a self-contained reader of its own retention,
  # and the two compose rather than fight: `example.display_exception=` writes the example's
  # `@exception`, so the hook that runs second (RSpec runs `after` hooks in definition-reverse
  # order) reads the FIRST hook's enriched exception and dups IT — one message carrying original
  # failure + first leg + second leg, and on the aggregate path two entries of their own. Each
  # hook clears only its own retention in its own `ensure`; between them both lists are empty
  # after every example, failed or not — the same discard discipline the rows_touched leg follows,
  # for the same leak class.
  PLAN_RELATION_STATISTICS_EVIDENCE_HEADER =
    "──── plan_for / plan_for_actual_sql relation statistics evidence (SPGD-1351) ────"

  # Carries the evidence into an aggregate's sub-failure list. Named for what it holds, because
  # that name is what the reader sees rendered beside the failed assertion.
  class PlanRelationStatistics < StandardError; end

  # The statistics snapshots this example retained, in invocation order. A call site may invoke a
  # plan helper more than once, and the failure names ONE plan, so order and table are what let a
  # reader tell which invocation produced it. Empty — and the hook therefore a no-op — for every
  # example that never called a retaining helper.
  def retained_plan_relation_statistics
    @retained_plan_relation_statistics ||= []
  end

  # `source` names the helper that took the snapshot, so the rendered label says which plan
  # assertion the numbers belong to. The default is the caller this machinery was built for;
  # every other retaining helper passes its own name.
  def retain_plan_relation_statistics(table, snapshot, source: "plan_for_actual_sql")
    retained_plan_relation_statistics <<
      { table: table.to_s, snapshot: snapshot, source: source.to_s }
  end

  def discard_retained_plan_relation_statistics
    @retained_plan_relation_statistics = nil
  end

  # The retained snapshots, formatted. ISSUES NO QUERY: every datum here was already in hand at
  # capture — the reader-facing reason the capture-time variant was chosen over a failure-path
  # re-read.
  def plan_relation_statistics_evidence
    lines = [
      PLAN_RELATION_STATISTICS_EVIDENCE_HEADER,
      "RelationStatistics.snapshot taken at the moment a plan helper ran its EXPLAIN, " \
      "while the example transaction was still open — the pg_class state the planner acted on, " \
      "not whatever the catalog carries after the rollback. Rendering it issued no query. Each " \
      "snapshot is labelled by the helper that took it, the table it was taken against and by " \
      "the order it was invoked in, because the failure names one plan and an example may " \
      "invoke a helper more than once."
    ]

    retained_plan_relation_statistics.each_with_index do |retained, index|
      lines << "── #{retained[:source]}(#{retained[:table].inspect}), invocation #{index + 1} ──"
      retained[:snapshot].each do |row|
        lines << "  #{row['relname']}: reltuples=#{row['reltuples']} relpages=#{row['relpages']}"
      end
    end

    lines << "──────────────────────────────────────────────────"
    lines.join("\n")
  end

  # Appends the retained snapshots to what the reader will SEE for a failing example, leaving the
  # original failure's class, backtrace and message text untouched above it — the same additive
  # mechanism, and the same original-failure-wins rescue, as `append_rows_touched_plan_evidence`,
  # whose section carries the full rationale for both shapes.
  def append_plan_relation_statistics_evidence(example)
    return if retained_plan_relation_statistics.empty?

    failure = example.exception
    return if failure.nil?

    evidence =
      begin
        plan_relation_statistics_evidence
      rescue StandardError => e
        "#{PLAN_RELATION_STATISTICS_EVIDENCE_HEADER}\ncould not be collected (#{e.class}: #{e.message})"
      end

    if defined?(RSpec::Core::MultipleExceptionError::InterfaceTag) &&
       RSpec::Core::MultipleExceptionError::InterfaceTag === failure
      # An aggregate is a LIST of failures; appending to its message would bury the evidence above
      # entries it does not belong to. It takes an entry of its own instead.
      note = PlanRelationStatistics.new(evidence)
      note.set_backtrace([])
      failure.add(note)
    else
      # Duplicated and re-messaged for the same reason its sibling is: a dup carries the
      # original's class, backtrace and every other attribute across for free — and, because
      # `display_exception=` writes `@exception`, the hook that runs after this one dups THIS
      # enriched exception, which is how the two legs land in one message.
      enriched = failure.dup
      message = "#{failure.message}\n#{evidence}"
      enriched.define_singleton_method(:message) { message }
      enriched.define_singleton_method(:to_s) { message }
      example.display_exception = enriched
    end
  ensure
    discard_retained_plan_relation_statistics
  end

  # One definition of the wiring, called by this file's own `RSpec.configure` below and by the
  # examples that exercise the mechanism against a sandboxed configuration. Two hand-rolled
  # copies would be free to drift in exactly the way this file's header warns about.
  def self.install_into(config)
    config.include self
    config.after { |example| append_rows_touched_plan_evidence(example) }
    config.after { |example| append_plan_relation_statistics_evidence(example) }
  end
end

RSpec.configure do |config|
  QueryCapture.install_into(config)
end
