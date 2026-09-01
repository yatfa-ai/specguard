# frozen_string_literal: true

# Evidence for a FAILED census assertion in the near-duplicates request spec, collected into the
# RSpec failure message itself.
#
# WHY THIS EXISTS: `repository_near_duplicates_spec.rb` reddens CI intermittently on unrelated
# PRs — four documented events (SPGD-879 on main at c192b15, the SPGD-878 audit run, one of three
# full-suite runs in SPGD-903 QA, and PR #275 AFTER the `hnsw.iterative_scan` mitigation had ridden
# eight consecutive green runs) — and every reddening captured ZERO evidence about why: a count
# mismatch and nothing else. `gh run rerun` is not available to the agent token, so the evidence
# is not merely missing, it is GONE after the fact, and whatever agent holds the approval review
# has to adjudicate blind. The corpus's own NEXT-OBSERVER'S RULE is "capture the full EXPLAIN
# before anything else"; this file mechanizes that rule for the HNSW family.
#
# WHAT IT COLLECTS — everything the four adjudications had to reconstruct by hand, and only on the
# failure path:
#
#   1. THE PLAN: `EXPLAIN (ANALYZE, BUFFERS)` of the pair read
#      (`SpecIdentity.near_duplicate_pairs_in`), captured OFF THE WIRE during the served request —
#      the suite's own rule, "captured off the wire rather than EXPLAINed from a hand-written
#      copy", stated four times over in `spec/models/spec_observation_spec.rb` — and re-issued
#      inside the SAME STILL-OPEN example transaction, where the fixture data and the production
#      `SET LOCAL` GUCs are both still live.
#   2. THE STATS: `pg_class.reltuples`/`relpages` for `spec_identities` and every index on it,
#      through `RelationStatistics.snapshot` — the very datum `relation_statistics.rb` exists to
#      manage, and a primary driver of the plan choice the EXPLAIN shows. Reused, not re-queried.
#   3. THE ENVIRONMENT: pgvector's `extversion` plus the effective `hnsw.ef_search` and
#      `hnsw.iterative_scan` — the CI-vs-grid version gap datum, since CI runs
#      `pgvector/pgvector:pg16` (`.github/workflows/ci.yml`) while every recall number behind the
#      shipped mitigation was measured on PostgreSQL 17.9 / pgvector 0.8.6.
#
# == The GUC asymmetry the EXPLAIN re-issue must respect
#
# At failure time, inside the still-open example transaction, the two planning inputs the read
# sets are in OPPOSITE states:
#
#   * `hnsw.iterative_scan = 'relaxed_order'` is STILL LIVE — `SET LOCAL` binds to the
#     transaction, which is the example's, and nothing discards it until rollback.
#   * `cpu_operator_cost` has been RESTORED — the read's own epilogue puts the previous value back
#     (`set_operator_cost(previous_cost)` in `near_duplicate_pairs_in`) precisely so callers do
#     not inherit the re-priced operator.
#
# A naive EXPLAIN re-issue would therefore plan under the DEFAULT operator cost, not the priced one
# the read used — and plan choice is exactly what moves with that GUC: pricing the 1024-dim `<=>`
# operator via `SpecIdentity::VECTOR_OPERATOR_COST` is the entire reason the quadratic plan is
# avoided. So the EXPLAIN is bracketed by the same re-apply the read itself makes —
# `SELECT set_config('cpu_operator_cost', …, true)`, the same function spelling `set_operator_cost`
# uses — with the pre-existing value echoed and put back afterwards, mirroring the read's own
# bookends. Both HNSW GUC values are echoed in the output regardless, so the reader can see what
# the read actually ran under.
#
# == Why the rescue is inside the example body
#
# Transactional fixtures roll the example's transaction back in an `after(:each)` hook. The
# evidence — the EXPLAIN above all — is only meaningful against that transaction (the fixture rows
# are in it; the `SET LOCAL` GUCs ride it), so it must be collected while the transaction is still
# open, on the same connection that served the request. `evidencing_near_duplicate_failure` wraps
# the request and the assertions, rescues `RSpec::Expectations::ExpectationNotMetError`, collects,
# and re-raises with the ORIGINAL failure text verbatim plus the appended evidence — strictly
# additive. An `around` hook's post-`example.run` stretch and an `after` hook both run OUTSIDE the
# transaction, against a connection that has already discarded the GUCs, so neither can collect
# what this collects.
#
# == The green path pays nothing
#
# The wire stash is a passive `sql.active_record` subscriber (the `query_capture.rb` pattern)
# installed around the block: it issues ZERO queries and records only the statement matching the
# pair read's signature. Every query this file issues — the `EXPLAIN`, the `pg_class` read, the
# `pg_extension` read, the GUC probes — fires from inside the rescue, which only a failure opens.
# The request spec pins exactly that with `queries_against(/EXPLAIN|pg_class|pg_extension/)` on a
# green census read.
#
# The evidence queries must equally never be issued inside a live `queries_against { }` window —
# an `EXPLAIN`, or the `'spec_identities'::regclass` catalog read, CONTAINS the `spec_identities`
# substring and would be counted by a subscriber watching that table. It cannot arise on the green
# path (the cost-assertion subscribers complete before their expectations evaluate), and this
# helper never widens one: the wrapper is not used around the file's cost assertions.
#
# == Deliberately NOT here
#
# No mitigation, no second-guessing among residual mechanisms, and no change to any GUC the
# production read sets: this file only instruments the failure. The recall-hardening decision is
# SPGD-72's (paused roadmap), and filing a mechanism guess is the wrong shape against this
# corpus's own precedent — the observer's job is to capture the plan, not to bet on one.
module NearDuplicateFailureEvidence
  # The pair read is identifiable on the wire by BOTH markers together: only
  # `near_duplicate_pairs_in`'s statement carries a `CROSS JOIN LATERAL` (twice — the neighbour
  # LATERAL and the weights LATERAL) and filters `b.distance <=` in the same statement. The served
  # request issues several OTHER queries against `spec_identities` (the population FILTER-count,
  # identity loads); none carries this signature.
  PAIR_READ_MARKERS = ["CROSS JOIN LATERAL", "b.distance <="].freeze

  # The evidence block, formatted. ISSUES QUERIES — the failure path only.
  def near_duplicate_failure_evidence
    connection = ActiveRecord::Base.connection

    [].tap do |lines|
      lines << "──── near-duplicates census failure evidence (SPGD-922) ────"
      lines << "Collected inside the still-open example transaction (fixture data live; the read's" \
               " SET LOCAL hnsw.iterative_scan still live), on the connection that served the" \
               " request. Nothing here ran on the green path."
      lines.concat(pair_read_plans(connection))
      lines.concat(relation_statistic_lines(connection))
      lines.concat(environment_lines(connection))
      lines << "──────────────────────────────────────────────────"
    end.join("\n")
  end

  # Wraps the served request AND the census assertions. The stash is passive; the rescue is where
  # every evidence query fires. The original failure text survives verbatim — the evidence is
  # appended, never substituted.
  #
  # TWO failure families are rescued, both drawn from the incident ledger rather than chosen by
  # guess: the COUNT MISMATCHES surface as `RSpec::Expectations::ExpectationNotMetError`
  # (`expected 1 got 0`, `10→7`), while the `clusters.sole` family surfaces as an ERROR, not an
  # expectation failure — ActiveSupport's `Enumerable#sole` raises
  # `Enumerable::SoleItemExpectedError` ("no item found" / "multiple items found"), which is one
  # of PR #275's five documented shapes. A rescue that caught only the expectation failure would
  # capture zero evidence for exactly that shape. Nothing wider is caught: these two are the
  # families the ledger names, and any other error inside the block propagates untouched.
  def evidencing_near_duplicate_failure(&body)
    stash_pair_reads(&body)
  rescue RSpec::Expectations::ExpectationNotMetError, Enumerable::SoleItemExpectedError => e
    with_appended_near_duplicate_evidence(e)
  ensure
    @near_duplicate_pair_reads = nil
  end

  private

  # The ORIGINAL failure always wins: if collecting evidence itself blows up, say so inline rather
  # than replacing the count mismatch with a collector stack trace. The re-raise keeps the failure's
  # own class, message and backtrace — the evidence is appended, never substituted.
  def with_appended_near_duplicate_evidence(original)
    evidence =
      begin
        near_duplicate_failure_evidence
      rescue StandardError => collector_error
        "──── near-duplicates census failure evidence (SPGD-922) ────\n" \
          "could not be collected (#{collector_error.class}: #{collector_error.message})"
      end

    enriched = original.class.new("#{original.message}\n#{evidence}")
    enriched.set_backtrace(original.backtrace)
    raise enriched
  end

  # The passive half: records the pair read's statement, and nothing else, issuing no queries.
  def stash_pair_reads(&body)
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if payload[:name] != "SCHEMA" && PAIR_READ_MARKERS.all? { sql.include?(_1) }
        stash = @near_duplicate_pair_reads ||= []
        stash << sql unless stash.include?(sql)
      end
    end
    body.call
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # The plan, re-issued under the read's own planning inputs. The statement arrived off the wire
  # FULLY LITERAL (`sanitize_sql_array` inlines the binds), so it can be EXPLAINed as captured —
  # no `unprepared_statement` gymnastics. `EXPLAIN (ANALYZE, …)` re-executes the read (read-only,
  # already-failing example), which is the point: the plan is measured against the very fixture
  # state that produced the mismatch.
  def pair_read_plans(connection)
    captured = Array(@near_duplicate_pair_reads)
    return [
      "PAIR READ PLAN — unavailable: no statement carrying both #{PAIR_READ_MARKERS.map { |m| "'#{m}'" }.join(' and ')} " \
      "was captured on the wire for this example (the request may have failed before the pair " \
      "read issued, or the read's shape changed and the signature no longer matches)."
    ] if captured.empty?

    previous_cost = connection.select_value("SHOW cpu_operator_cost")
    begin
      connection.execute(ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT set_config('cpu_operator_cost', ?, true)", SpecIdentity::VECTOR_OPERATOR_COST.to_s ]
      ))
      plans = captured.map do |sql|
        connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}").join("\n")
      end
    ensure
      connection.execute(ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT set_config('cpu_operator_cost', ?, true)", previous_cost.to_s ]
      ))
    end

    lines = [
      "PAIR READ PLAN — EXPLAIN (ANALYZE, BUFFERS), captured off the wire and re-issued under the " \
      "read's own planning inputs: cpu_operator_cost was re-applied to " \
      "SpecIdentity::VECTOR_OPERATOR_COST (#{SpecIdentity::VECTOR_OPERATOR_COST}) for this EXPLAIN " \
      "because the read's epilogue restores it before the assertion failed (it was " \
      "#{previous_cost} before this re-apply); hnsw.iterative_scan is still live from the read's " \
      "SET LOCAL."
    ]
    plans.each_with_index { |plan, index| lines << (plans.one? ? plan : "  ── pair read #{index + 1} ──\n#{plan}") }
    lines
  end

  # The poisoning datum `relation_statistics.rb` documents: reltuples/relpages for the table and
  # every index on it, through that file's own snapshot — not a second query shape.
  def relation_statistic_lines(connection)
    lines = [
      "CATALOG STATISTICS — pg_class at failure time, via RelationStatistics.snapshot(" \
      "\"spec_identities\") (the datum relation_statistics.rb manages; reltuples is a primary " \
      "driver of the plan choice above):"
    ]
    RelationStatistics.snapshot("spec_identities").each do |row|
      lines << "  #{row['relname']}: reltuples=#{row['reltuples']} relpages=#{row['relpages']}"
    end
    lines
  end

  # The CI-vs-grid version gap datum. `current_setting(name, true)` — the missing_ok spelling —
  # because pgvector's GUCs register when the library loads into the backend, and a session that
  # has not yet touched a vector operator does not have them; a NULL is the honest reading there,
  # not a raise. By failure time the pair read has run on this very connection, so both are live.
  def environment_lines(connection)
    extversion = connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
    ef_search = connection.select_value("SELECT current_setting('hnsw.ef_search', true)")
    iterative_scan = connection.select_value("SELECT current_setting('hnsw.iterative_scan', true)")

    [
      "ENVIRONMENT — pgvector extversion=#{extversion}  hnsw.ef_search=#{ef_search}  " \
      "hnsw.iterative_scan=#{iterative_scan}  (CI runs .github/workflows/ci.yml's " \
      "pgvector/pgvector:pg16; the recall grid behind the shipped mitigation was measured on " \
      "PostgreSQL 17.9 / pgvector 0.8.6.)"
    ]
  end
end
