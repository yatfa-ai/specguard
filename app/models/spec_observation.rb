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

  # How many rows a ranking returns. Named because the panel's caption reports the figure back to
  # the reader, and a sentence explaining a list's length must not be able to disagree with it.
  SLOWEST_LIMIT = 10

  # How many spec FILES a by-file rollup returns. Its own constant rather than a reuse of
  # `SLOWEST_LIMIT`: the two rank different populations — one run has far fewer files than
  # examples — so a suite that wants twenty files ranked has no reason to want twenty examples
  # ranked, and one number standing for both would make that a single edit nobody meant to make.
  HEAVIEST_FILES_LIMIT = 10

  # Rows that carry a measurement. **The exclusion is in SQL, and it is load-bearing.**
  #
  # `duration_seconds` is nullable by design: `Ingest::ObservationRecorder#attributes` writes
  # `result&.run_time`, so an example that never ran records a faithful nil rather than a zero. And
  # `duration_seconds: :desc` is **NULLS FIRST** in Postgres — so a naive ordering heads a list
  # captioned "slowest" with the examples that did not run at all.
  #
  # `TestRun#shard_durations` documents this hazard one grain up and ends with the rule this obeys:
  # *"either keep the gate or order `NULLS LAST` first"*. There is no example-grain equivalent of
  # `TestRun#wall_clock_decomposable?` — nothing in the schema establishes that every example
  # reported — so these rows are excluded rather than gated behind a predicate that does not exist.
  #
  # Excluded in the WHERE clause rather than rejected in Ruby afterwards, for two reasons that are
  # both about the same rows. A Ruby filter sorts the run's entire slice before discarding anything,
  # which is the cost `#slowest_in`'s index exists to avoid; and it discards *after* the `LIMIT`,
  # so it hands back fewer than the requested rows on exactly the runs the exclusion matters for.
  scope :timed, -> { where.not(duration_seconds: nil) }

  # The slowest examples of ONE run, slowest first — the question this table's composite index
  # (`index_spec_observations_on_test_run_id_and_duration_seconds`) was built for. Scoped to a
  # single `test_run_id` and capped, it is an indexed backward scan: constant in suite size, which
  # is what makes it safe at the 20,000-example design point rather than a sort over every row the
  # run wrote.
  #
  # One run, never a repository's history. `example_id` is positional and explicitly not stable
  # across refactors (see the class comment above), so a ranking that spanned runs would be
  # comparing rows that are not known to be the same test. That boundary is the model's, and this
  # method stays on the near side of it.
  #
  # `id` breaks ties, so a run whose examples tie to the millisecond has a total, stable order
  # rather than one the query planner picks afresh on each request.
  def self.slowest_in(test_run, limit: SLOWEST_LIMIT)
    where(test_run_id: test_run.id).timed.order(duration_seconds: :desc, id: :asc).limit(limit)
  end

  # Everything a surface has to say ABOUT one run's slice before it is allowed to show ten rows of
  # it, as one SELECT. Ordered, named, and kept in one constant because the names are what the
  # caller destructures and the expressions are what a plan assertion EXPLAINs — two lists that
  # drifted apart would be a caption counting a column nobody selected.
  #
  # `COUNT(duration_seconds)` and `COUNT(outcome)` count NON-NULLS. The first is exactly the
  # population `.timed` selects, so the caption cannot describe a different row set from the one
  # the ranking scanned. The second is the population that said anything at all about how its
  # example ended — and it is separate from the failure count on purpose. `outcome` is nullable and
  # `Ingest::ObservationRecorder#attributes` writes it through `presence_of`, so a run whose client
  # sends no outcomes stores a nil on every row; without this figure the only thing distinguishing
  # that run from a clean one is a zero, and "nothing to check" wearing the spelling of "everything
  # passed" is the one reading this table must not produce.
  #
  # `failed` and `pending` are counted BY NAME, and there is deliberately no third counter for
  # "passed". Nothing platform-side validates the string — `Ingest::Payload` does not, and the
  # client sends `result&.status&.to_s` — so a remainder computed as `reported - failed - pending`
  # is a population this code has not read a verdict into, and that is the honest shape for it.
  #
  # NOT `where(outcome: "failed").count`, even though `index_spec_observations_on_test_run_id_and_outcome`
  # exists and is certified for exactly that predicate. That index is built for NARROWING to the
  # failures — the "which tests failed" list a later slice will want — and using it here would mean
  # a second round trip for a figure the scan below already has the rows for. The one-read rule is
  # `SlowestExamples`': a caption fetched separately from the list it describes is a claim with no
  # structural reason to keep agreeing with it. Leave this as a FILTER aggregate.
  COVERAGE_COUNTS = {
    recorded_count: "COUNT(*)",
    timed_count: "COUNT(duration_seconds)",
    reported_outcome_count: "COUNT(outcome)",
    failed_count: "COUNT(*) FILTER (WHERE outcome = 'failed')",
    pending_count: "COUNT(*) FILTER (WHERE outcome = 'pending')"
  }.freeze

  # One run's slice, counted every way the panel above it has to state — in a single round trip.
  #
  # Deliberately NOT `TestRun#total_specs_count` for any of it. That figure is re-derived by SUM
  # over `test_run_shards` and the class comment above is explicit that nothing here re-derives it;
  # the two can legitimately disagree, since `Ingest::ObservationRecorder#record` writes a row count
  # that is *"not always `specs.size`"*. Coverage of a ranking is a fact about the rows ranked.
  #
  # Every value is `to_i`'d: a run that recorded nothing still returns a row of zeroes from an
  # aggregate, and the caller wants integers rather than a mix of those and nils.
  #
  # @return [Hash{Symbol=>Integer}] keyed by `COVERAGE_COUNTS`' names, in its order.
  def self.coverage_in(test_run)
    counts = where(test_run_id: test_run.id).pick(*COVERAGE_COUNTS.values.map { |sql| Arel.sql(sql) })

    COVERAGE_COUNTS.keys.zip(Array(counts)).to_h { |name, count| [name, count.to_i] }
  end

  # Where ONE run's wall clock went, rolled up by spec file, heaviest first — the question the
  # class comment above says this table exists to answer and which nothing in `app/` had ever
  # asked. A ranking of individual examples cannot answer it: at the 20,000-example design point
  # `SLOWEST_LIMIT` shows 0.05% of the suite ordered by *individual* cost, and a file holding 400
  # examples at 50ms each is twenty seconds of the run with every one of its rows far below the
  # head. Outliers and concentration are different questions.
  #
  # Grouped on `spec_file_path` — the INCLUDING file — so a shared example group's time lands on
  # the file that ran it rather than on a `spec/support/` helper (see "Two paths, two meanings"
  # above, and the end-to-end pin in spec/requests/api/v1/ingest_spec.rb). The key cannot be null:
  # `Ingest::ObservationRecorder#attributes` falls back to `file_path` for a producer old enough
  # not to send one, precisely so no row drops out of a by-file total.
  #
  # @return [Array<Array>] `[spec_file_path, total_seconds, recorded_count, timed_count, file_count]`
  #   per file, where `file_count` is the same figure on every row: how many files the run touched
  #   in total, before the `LIMIT`.
  #
  # == Why four columns and not one SUM
  #
  # `SUM` skips NULLs SILENTLY, and `duration_seconds` is nullable by design — an example that
  # never ran records a faithful nil. Unlike `#slowest_in`, exclusion is not available here:
  # dropping untimed rows changes each surviving group's own POPULATION, so a file with 400
  # examples of which 200 went untimed would report a total that understates by half and say
  # nothing about it. So every group carries how many of its rows reported a timing, counted in
  # the same pass: `COUNT(*)` against `COUNT(duration_seconds)`, which counts non-nulls. One
  # grouped aggregate for the whole panel — a per-file follow-up query would be a trip per row.
  #
  # == `pluck`, deliberately, and `NULLS LAST`
  #
  # Both are about the file whose examples were ALL untimed, whose SUM is SQL NULL:
  #
  # * `group(...).sum(:duration_seconds)` casts that NULL to `0.0` on the way back into Ruby, and
  #   a surface handed a zero renders "0.00s" — a run that measured nothing wearing the spelling
  #   of a measurement. `#duration_label` refuses exactly that reading one grain down. `pluck`
  #   hands the nil back intact so the caller can tell the two apart.
  # * `SUM(...) DESC` is NULLS FIRST in Postgres, so the naive ordering does not merely include
  #   that file — it names it the heaviest file in the suite. Same hazard `scope :timed` documents
  #   at the example grain, and the ordering has to answer it here because the row is not excluded.
  #
  # `spec_file_path` breaks ties, so a run whose files total equally has one stable order rather
  # than one the planner picks afresh per request.
  #
  # == Why the row count comes back on every row
  #
  # This read is `LIMIT`ed, so its own length is the TRUNCATED count and a caller holding it cannot
  # tell "the ten heaviest of three hundred files" from "all three files this run touched". That is
  # the same lie by omission the four columns above exist to refuse, one grain up: a figure that
  # does not state what it was drawn from. A second `COUNT(DISTINCT spec_file_path)` would be a
  # second round trip for one clause of one sentence — the objection `.coverage_in` answers.
  #
  # `COUNT(*) OVER ()` is evaluated AFTER `GROUP BY` and BEFORE `LIMIT`, so it counts groups, not
  # rows, and counts all of them however few are returned. It rides back on every row carrying the
  # same value; the caller reads it off whichever row it has and gets nothing for an empty run,
  # which is the correct answer there.
  def self.file_durations_in(test_run, limit: HEAVIEST_FILES_LIMIT)
    where(test_run_id: test_run.id)
      .group(:spec_file_path)
      .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), Arel.sql("spec_file_path ASC"))
      .limit(limit)
      .pluck(Arel.sql("spec_file_path"), Arel.sql("SUM(duration_seconds)"),
             Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
             Arel.sql("COUNT(*) OVER ()"))
  end

  # How many distinct descriptions one narrowing may hand the composition step below.
  #
  # A catastrophe valve, not a display limit. The candidate step asks for the descriptions that
  # failed ANYWHERE in the window, and on a suite that went entirely red — a bad merge, a missing
  # fixture, a service that would not boot — that is every test in it. At the roadmap's 20,000
  # example design point an uncapped candidate list is a 20,000-element `IN` clause handed to the
  # composition query, which is the O(suite) work the two-step shape exists to refuse. So the list
  # stops here, and `UnstableTests#truncated?` carries the fact that it stopped: a cap that does
  # not disclose itself turns "we looked at everything" and "we looked at the first two hundred"
  # into the same panel.
  UNSTABLE_CANDIDATE_LIMIT = 200

  # Which runs of a window recorded example rows at all, and which of them said how any of those
  # examples ended — the two facts a cross-run outcome comparison has to establish BEFORE it is
  # allowed to compare anything.
  #
  # `outcome` is nullable and `Ingest::ObservationRecorder#attributes` writes it through
  # `presence_of`, so a producer that sends no outcomes stores a nil on every row of every run.
  # Such a window yields no failures, therefore no candidates, therefore an empty list — and an
  # empty list rendered as "nothing is unstable" is *Vacuous Green* exactly: "nobody told us"
  # wearing the spelling of "everything is fine". `reported_outcome_count` answers that hazard one
  # grain down for a single run (see `COVERAGE_COUNTS`); this is the same question asked of a
  # window, and its answer is counted in RUNS because the comparison it gates needs two of them.
  #
  # == Why this is an EXISTS per run and not one aggregate over the window
  #
  # `COUNT(DISTINCT test_run_id) FILTER (WHERE outcome IS NOT NULL)` is the obvious spelling and it
  # reads every row in the window to produce two integers — 600,000 of them at thirty runs of a
  # 20,000-example suite, for a question whose answer is decided by the FIRST matching row of each
  # run. The lateral asks the index that question once per run instead: at most `2 × window` index
  # probes, none of which touches a row past the one that answers it, and the cost follows the
  # window's length rather than the suite's size. `index_spec_observations_on_test_run_id_and_outcome`
  # answers the second probe without a heap visit at all.
  WINDOW_OUTCOME_REPORTING_SQL = <<~SQL.squish.freeze
    SELECT COUNT(*) FILTER (WHERE probe.has_rows) AS runs_with_rows,
           COUNT(*) FILTER (WHERE probe.reported_outcome) AS runs_reporting_outcomes
    FROM unnest(ARRAY[:run_ids]::bigint[]) AS window_run(id)
    CROSS JOIN LATERAL (
      SELECT EXISTS (SELECT 1 FROM spec_observations o
                     WHERE o.test_run_id = window_run.id) AS has_rows,
             EXISTS (SELECT 1 FROM spec_observations o
                     WHERE o.test_run_id = window_run.id AND o.outcome IS NOT NULL) AS reported_outcome
    ) probe
  SQL

  private_constant :WINDOW_OUTCOME_REPORTING_SQL

  # @return [Hash{Symbol=>Integer}] `runs_with_rows` and `runs_reporting_outcomes`, both counted in
  #   runs of the window handed in, never in rows.
  def self.window_outcome_reporting(run_ids)
    return { runs_with_rows: 0, runs_reporting_outcomes: 0 } if run_ids.empty?

    row = connection.select_one(sanitize_sql_array([WINDOW_OUTCOME_REPORTING_SQL, { run_ids: run_ids }]))

    { runs_with_rows: row["runs_with_rows"].to_i, runs_reporting_outcomes: row["runs_reporting_outcomes"].to_i }
  end

  # Step one of two: the descriptions that recorded a FAILURE somewhere in the window — the only
  # descriptions whose outcome can have changed within it, since a test that never failed here has
  # nothing to have changed from.
  #
  # This is the read `index_spec_observations_on_test_run_id_and_outcome` was built for and which
  # `COVERAGE_COUNTS` above declines to use, in as many words: *"that index is built for NARROWING
  # to the failures — the 'which tests failed' list a later slice will want"*. This is that later
  # slice, and the narrowing is what makes the whole panel affordable. Grouping the window's rows
  # by `name` directly is 600,000 rows aggregated per page load at the design point; grouping only
  # the failures is a scan of the failures.
  #
  # Nothing correct is lost. A test that reported only non-failing outcomes across the window may
  # well have varied — `pending` one run and `passed` the next — and that variance is deliberately
  # out of this panel's scope, which the panel states rather than leaves to be discovered.
  #
  # A null `name` is excluded HERE rather than after the fact, because a null cannot be matched to
  # itself across runs: two nulls are not known to be one test, and `GROUP BY name` would pool
  # every unnamed example of every run of the window into one fictional test with a fictional
  # history. How many rows that excludes is a separate question, asked by `.unnamed_row_count_in`
  # and stated on the panel — silently dropping them is the reading this must not produce.
  #
  # == The ordering, and what the cap therefore keeps
  #
  # Fewest failures first. The cap is only ever reached by a window in which more than
  # `UNSTABLE_CANDIDATE_LIMIT` distinct descriptions failed — a suite that has gone broadly red —
  # and in that window the descriptions that failed in EVERY run are precisely the ones whose
  # outcome did not change. Keeping the least-failing end of the list therefore keeps the end this
  # panel can still say something true about, and `name` breaks ties so the kept set is stable
  # between two requests rather than whatever the planner returned first.
  #
  # `COUNT(*) OVER ()` is evaluated AFTER `GROUP BY` and BEFORE `LIMIT`, so it counts candidate
  # DESCRIPTIONS and counts all of them however few are returned — the truncation-disclosure shape
  # `#file_durations_in` documents at length, riding back on every row for no second round trip.
  #
  # @return [Array<Array>] `[name, candidate_count]` per kept description, where `candidate_count`
  #   is the same figure on every row: how many descriptions failed in the window in all.
  def self.unstable_candidates_in(run_ids, limit: UNSTABLE_CANDIDATE_LIMIT)
    return [] if run_ids.empty?

    where(test_run_id: run_ids, outcome: "failed")
      .where.not(name: nil)
      .group(:name)
      .order(Arel.sql("COUNT(*) ASC"), Arel.sql("name ASC"))
      .limit(limit)
      .pluck(Arel.sql("name"), Arel.sql("COUNT(*) OVER ()"))
  end

  # Everything the panel has to say about ONE description across the window, as one grouped
  # aggregate over the candidates only — ordered, named, and kept in one constant for the reason
  # `COVERAGE_COUNTS` is: the names are what the caller destructures and the expressions are what a
  # plan assertion EXPLAINs, and two lists that drifted apart would be a row counting a column
  # nobody selected.
  #
  # `run_count` beside `recorded_count` is the load-bearing pair. The grouping key is the
  # description ALONE (see `.unstable_candidates_in`), and a description is not a key within a
  # single run: a table-driven loop, a shared example group or two genuinely identical `it` strings
  # put several examples under one description in the same run. Such a group holds a `failed` and a
  # `passed` in one run and would read, through any figure that did not distinguish them, as a test
  # that flipped between runs. `COUNT(*) > COUNT(DISTINCT test_run_id)` is that distinction, taken
  # in the same pass — see `UnstableTests::Row#shared_description?`, which is what the surface says
  # it with.
  #
  # `failed_run_count` beside `failed_count` for the same reason: "failed in 3 of the 12 runs it
  # appeared in" is a sentence about runs, and counting rows would tell a reader that a description
  # carried by four examples failed four times in one run.
  #
  # `ARRAY_AGG(DISTINCT …) FILTER (WHERE … IS NOT NULL)` for both lists, so a null never arrives as
  # a nil element inside an array the surface iterates. The outcome words are echoed verbatim and
  # never folded into a verdict, for the reason `#outcome_label` gives: nothing platform-side
  # validates that string. The file paths are what makes a MOVED test visible — per the project's
  # semantic-identity rule a test that moved is the same test and keeps its history, so a group
  # spanning two files is a disclosure and not an error, but the reader is told.
  UNSTABLE_COMPOSITION = {
    recorded_count: "COUNT(*)",
    run_count: "COUNT(DISTINCT test_run_id)",
    reported_outcome_count: "COUNT(outcome)",
    failed_count: "COUNT(*) FILTER (WHERE outcome = 'failed')",
    failed_run_count: "COUNT(DISTINCT test_run_id) FILTER (WHERE outcome = 'failed')",
    outcomes: "ARRAY_AGG(DISTINCT outcome) FILTER (WHERE outcome IS NOT NULL)",
    file_paths: "ARRAY_AGG(DISTINCT spec_file_path) FILTER (WHERE spec_file_path IS NOT NULL)"
  }.freeze

  # Step two of two: how each candidate description behaved across the whole window — over the
  # candidates only, which is what keeps this off the whole window's rows.
  #
  # Scoped by `repository_id` as well as by the window's runs, and that is not belt-and-braces: it
  # is the leading column of `index_spec_observations_on_repository_id_and_name`, the index this
  # read rides and the one `SpecObservation`'s own comments have been reserving. Without it there
  # is no index on `name` to walk and the grouping falls back to reading the runs whole.
  #
  # @return [Array<Array>] `[name, *UNSTABLE_COMPOSITION.values]` per description, in that order.
  def self.outcome_composition_in(repository_id:, run_ids:, names:)
    return [] if names.empty? || run_ids.empty?

    where(repository_id: repository_id, test_run_id: run_ids, name: names)
      .group(:name)
      .pluck(Arel.sql("name"), *UNSTABLE_COMPOSITION.values.map { |sql| Arel.sql(sql) })
  end

  # How many rows of the window carried no description at all — the figure the panel states when it
  # excludes them.
  #
  # A null `name` is not a test this read can follow across runs: two nulls in two runs are not
  # known to be one example, so they are dropped from the matching rather than pooled. Dropping
  # them silently is the failure mode — a panel that examined a tenth of the window and said
  # nothing about the other nine is a claim about a population it did not read. `Ingest::Payload`
  # refuses a spec carrying neither intent nor name, but `Ingest::SpecSignal` records that
  # pre-validator rows exist, and an annotated spec from a producer sending no name stores a null
  # here today.
  #
  # `repository_id` leads for the same reason as above: `WHERE repository_id = ? AND name IS NULL`
  # walks `index_spec_observations_on_repository_id_and_name` — a btree indexes its nulls — so the
  # count costs what the unnamed rows cost and not what the window does.
  def self.unnamed_row_count_in(repository_id:, run_ids:)
    return 0 if run_ids.empty?

    where(repository_id: repository_id, test_run_id: run_ids, name: nil).count
  end

  # What to call this row on a surface that lists it. `name` is what the client sent as the
  # example's full description and is the only label a reader recognises — but it is nullable
  # (`Ingest::ObservationRecorder#attributes` writes it through `presence_of`, so a producer that
  # sends nothing, or sends `""`, stores a nil), and a blank cell in a ranked list is a row the
  # reader can neither identify nor go and find.
  def label = name.presence || location_label

  # Where to go and look. `file_path` and `line_number` are ONE coordinate — the definition site,
  # per the class comment above — and they are rendered as one.
  #
  # Specifically NOT `spec_file_path` + `line_number`. `spec_file_path` is the *including* file and
  # differs from `file_path` only for a shared example group, which is exactly the case where the
  # line number describes a line in the other file: pairing them would print a coordinate whose two
  # halves come from different files and point at whatever happens to sit on that line of the
  # including one. Equal for every ordinary example, so this costs nothing on the common row and
  # stays true on the uncommon one.
  def location_label = "#{file_path}:#{line_number}"

  # This row's duration, rendered.
  #
  # Guarded on nil even though `.timed` excludes those rows from every ranking: the column is
  # nullable and this is a public method on the record, so an ungated `nil` here would format as
  # "0.00s" — "the client sent no timing" made byte-identical to "this test took no time".
  def duration_label = self.class.humanized_duration(duration_seconds)

  # A number of seconds at THIS table's grain, rendered — the one formatting seam for every
  # duration read off these rows, whether it is one example's measurement or a whole file's total.
  #
  # Per-example durations sit two orders of magnitude below the run and shard figures the rest of
  # the dashboard prints, and `TestRun.humanized_seconds` rounds to a tenth of a second: a real
  # 0.04s measurement renders "0.0s" through it. At the head of a list captioned "slowest", a
  # measurement wearing the spelling of a zero is the one reading this must not produce — so
  # sub-minute values carry two decimals, and a value the two decimals cannot separate from zero
  # says that it is below the resolution rather than printing a zero it did not measure.
  #
  # A minute and over delegates to `TestRun.humanized_seconds`, so a four-minute example reads
  # "4m 12s" — the same words this page already gives a run or a shard of that length.
  #
  # A nil says so in words. Both callers can produce one and they mean the same thing: an example
  # the client never timed, and a whole file none of whose examples were timed — in both cases
  # nothing was measured, which is not a zero and must not be spelled like one.
  def self.humanized_duration(seconds)
    return "not reported" if seconds.nil?
    return TestRun.humanized_seconds(seconds) if seconds >= 60
    return "< 0.01s" if seconds.positive? && seconds < 0.01

    format("%.2fs", seconds)
  end

  # What CI said happened to this example, rendered — and NOTHING this application decided.
  # SpecGuard does not run tests; it reports what a client sent, which makes this a stability
  # observation and never a verdict on whether the example is correct.
  #
  # The known names are echoed verbatim rather than reworded, so the cell says the word the reader
  # will see in their own CI log. An UNKNOWN string is echoed too: nothing platform-side validates
  # this column — `Ingest::Payload` does not, and `Ingest::ObservationRecorder#attributes` stores
  # `result&.status&.to_s` through `presence_of` — so quoting what arrived is the only reading that
  # cannot be wrong. What this must not do is fold an unrecognised value into "passed".
  #
  # Nil is the one that decides whether this column is worth having. It is the exact hazard
  # `#duration_label` above carries a guard and a paragraph for, wearing the worse colour: a blank
  # cell, or one silently reading as green, would make "the client sent no outcome" byte-identical
  # to "this test passed" — on a row that is in this list precisely because it was slow, and may
  # have been slow because it was hanging on its way to failing.
  def outcome_label = outcome.presence || "not reported"

  # Which `UI::BadgeComponent` tone that word wears, so the distinction above survives a reader who
  # is scanning the column rather than reading it.
  def outcome_tone = self.class.outcome_tone(outcome)

  # The same decision made about a bare string, for a surface holding outcome words that came back
  # from an aggregate rather than off a row — the cross-run panel lists the DISTINCT words a
  # description was seen wearing, and those arrive as text out of `ARRAY_AGG`. One seam for both,
  # so a word cannot be coloured one way in a single run's column and another way across a window.
  #
  # Only the three RSpec names the producer is known to send are given a colour. Everything else —
  # an unrecognised string AND a nil — is `:neutral`, because a tone is a claim: green over a value
  # nobody validated would be this page asserting a pass it was never told about. The two neutral
  # cases are still distinguishable from each other by their text, which is what `#outcome_label`
  # is for; what they share is that neither of them is a pass.
  def self.outcome_tone(outcome)
    case outcome
    when "failed" then :error
    when "pending" then :warning
    when "passed" then :success
    else :neutral
    end
  end
end
