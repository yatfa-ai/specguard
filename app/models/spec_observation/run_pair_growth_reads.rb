# frozen_string_literal: true

# THE RUN-OVER-RUN GROWTH READS OF `SpecObservation`, MOVED OUT WHOLE — the four class methods that
# compare TWO runs and nothing else: `directory_growth_between`, `file_growth_between`,
# `directory_runtime_growth_between` and `file_runtime_growth_between`. `SpecObservation` `extend`s
# this module, so every caller keeps spelling them `SpecObservation.<method>` and the receiver is
# still the model class (`where`, `sanitize_sql_array` and the constants resolve as before).
#
# MOVE ONLY. Every method body and comment below is byte-identical to what it was in
# `app/models/spec_observation.rb`; the sole code edit is `def self.x` -> `def x`, and the emitted
# SQL did not change. The comments still say "above", "below" and `{.foo}`, and those coordinates
# are RELATIVE TO THE OLD FILE — they were not rewritten, so read a position word as pointing into
# `SpecObservation`, not into this module.
#
# THE CONSTANTS STAY ON `SpecObservation`. This module is nested lexically inside the class, so the
# unqualified `MOVED_DIRECTORIES_LIMIT`, `RETIMED_DIRECTORIES_LIMIT`,
# `SPEC_DIRECTORY_FILE_GROWTH_LIMIT`, `SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT` and
# `DIRECTORY_EXPRESSION` resolve exactly as they did, and a `stub_const("SpecObservation::...")`
# in a spec still bites because the lookup happens at call time.
class SpecObservation < ApplicationRecord
  module RunPairGrowthReads
    # How each code AREA's example count MOVED between two runs — the first read on this table that
    # spans more than one `test_run_id`, and the reason it is allowed to is worth stating precisely.
    #
    # == It compares POPULATIONS, and matches no rows
    #
    # Every other read here is scoped to one run because `example_id` is positional and explicitly
    # not stable across refactors (see the class comment and `.slowest_in`), so a ranking spanning
    # runs would be pairing rows not known to be the same test. **This pairs none.** It counts the
    # rows in each area of run A and the rows in each area of run B and subtracts the two integers.
    # No per-example key crosses the boundary, no example is matched to another example, and nothing
    # here claims a given test is the same test. That caution is about matching ROWS and this read
    # matches none of them — which is why it does not reopen the question the caution closes. A
    # future edit that joins these runs on `example_id`, or on any other per-example key, has left
    # what this method is allowed to say.
    #
    # == What a count here is, and is not
    #
    # `COUNT(*)` over each run's own rows, never `TestRun#total_specs_count`: that column is
    # re-derived by SUM over shard reports and `Ingest::ObservationRecorder#record` returns a row
    # count *"not always `specs.size`"*, so the two can legitimately differ — and there is no
    # by-directory counter anywhere else to borrow in any case. The caller is responsible for having
    # established that a difference between the two runs is a change in the SUITE rather than in how
    # much of it has been reported; `SpecDirectoryGrowth` is where that gate lives.
    #
    # == FILTER aggregates, not a two-key grouping pivoted in Ruby
    #
    # One group per AREA with each side counted by its own `FILTER`, rather than grouping on
    # `(directory, test_run_id)` and pivoting the pairs afterwards. The two read the same rows and
    # cost the same scan; what only this shape can do is rank and cap in SQL. `ABS(...) DESC` needs
    # both sides of the subtraction on ONE row, and with them there the `COUNT(*) OVER ()` counts
    # AREAS before the `LIMIT` — the same total-before-cap the by-directory rollup above uses, for
    # the same reason: a caption reading "the 10 of 63 areas that moved most" cannot then be
    # describing a different row set from the table under it. A pivot would have to take its ranking
    # and its cap in Ruby over every group of both runs, and count its areas off a Hash built after
    # the fact.
    #
    # `FILTER` over `CASE WHEN`/`SUM` because it is the same construct the outcome counters on this
    # table already use, and the plan certification there records what it costs: new expressions over
    # a row set the surrounding `COUNT(*)` already reads add no scan of their own.
    #
    # == An absent area is not a zero, and the caller is told which
    #
    # A group exists here if and only if at least ONE of the two runs wrote a row for that area, so a
    # side reading 0 wrote nothing for it. Whether that means "new area" or "this run recorded
    # nothing at all" is not decidable from the row — so the two `SUM(...) OVER ()` totals report
    # each run's whole recorded population, before the `LIMIT` and independent of it. A caller
    # holding a zero on one of those knows the side is empty and can withhold the comparison instead
    # of rendering an entire suite as deleted.
    #
    # Ranked by ABSOLUTE movement, both directions. A suite that deleted 300 examples from one area
    # answers "which areas moved" exactly as much as one that added them, and a `DESC`-only ranking
    # on the signed change would put every deletion below every addition and off the end of the cap.
    # `DIRECTORY_EXPRESSION` breaks ties, so two areas that moved equally have a stable order rather
    # than one the planner picks afresh per request.
    #
    # == Why this needs no index of its own
    #
    # It narrows on `test_run_id` — an `IN` list of two — and groups on an EXPRESSION, and only the
    # first decides the access path. `index_spec_observations_on_test_run_id` serves it and the
    # grouping hash-aggregates on top; two runs is twice the rows, not a different shape.
    # EXPLAIN-certified at the 20-run seed in spec/models/spec_observation_spec.rb rather than argued
    # for here.
    #
    # This used to add "which is the plan `.directory_durations_in` gets one method up". It is not,
    # any more: that read acquired a `COUNT(DISTINCT name)`, which disqualifies hashed aggregation
    # outright and buys it a sort. This read has no `DISTINCT` aggregate and does still hash — the
    # two facts simply stopped being the same fact, so it is stated here on its own evidence.
    #
    # @return [Array<Array>] `[directory, previous_count, latest_count, directory_count,
    #   previous_recorded, latest_recorded]` per directory, ranked by absolute movement. The last
    #   three are the same figures on every row: how many areas the two runs touched between them,
    #   and how many rows each run recorded in total — all three counted before the `LIMIT`.
    def directory_growth_between(test_run, previous_test_run, limit: MOVED_DIRECTORIES_LIMIT)
      latest = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", test_run.id])
      previous = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", previous_test_run.id])

      where(test_run_id: [test_run.id, previous_test_run.id])
        .group(Arel.sql(DIRECTORY_EXPRESSION))
        .order(Arel.sql("ABS(#{latest} - #{previous}) DESC"), Arel.sql("#{DIRECTORY_EXPRESSION} ASC"))
        .limit(limit)
        .pluck(Arel.sql(DIRECTORY_EXPRESSION), Arel.sql(previous), Arel.sql(latest),
               Arel.sql("COUNT(*) OVER ()"),
               Arel.sql("SUM(#{previous}) OVER ()"), Arel.sql("SUM(#{latest}) OVER ()"))
    end

    # How ONE area's individual spec FILES moved between two runs — `.directory_growth_between` above
    # at one grain down, narrowed to the area a reader picked out of it.
    #
    # == What it lets a reader do that the panel above cannot
    #
    # That panel's own caption discloses a doubt it then gives the reader no way to resolve: a test
    # that was MOVED is the same test, so a renamed or relocated directory appears there as one area
    # growing and another shrinking by the same amount, with nothing added and nothing deleted. The
    # disclosure is correct and it is unactionable — an area at `+47` and another at `−47` is the same
    # shape whether somebody moved forty-seven tests or wrote forty-seven and deleted forty-seven
    # others.
    #
    # At the FILE grain the two shapes stop looking alike. `spec/models/user_spec.rb 0 → 47` beside
    # `spec/legacy/user_spec.rb 47 → 0` reads as a relocation at a glance; `billing_spec.rb 3 → 50`
    # does not. This read asserts NEITHER of those readings — it counts rows per file per run exactly
    # as its parent counts them per area, and pairs no example with any other example, which
    # `SpecObservation`'s positional-instability rule forbids at every grain. It puts the operands in
    # front of the reader and lets them do the pairing the application is not allowed to do for them.
    #
    # == The narrow is an EQUALITY, exactly as `.files_in_directory` is
    #
    # Through `DIRECTORY_EXPRESSION` and `= ?`, never a prefix `LIKE`: `spec/models/orders` is its own
    # area here as it is its own row in the panel this drills out of, so these rows partition the area
    # the way that panel's partition the run. `.files_in_directory` carries the full argument,
    # including why a subtree would want the `text_pattern_ops` index — and therefore the migration —
    # that this read does not.
    #
    # It matters twice as much here as it does there, because the link that opens this panel is the
    # SAME `?spec_directory=` the durations drill-down answers. Two reads answering one ask through
    # two different definitions of what an area IS would open one panel with rows beside another that
    # says the area is empty, on one click. Hence the shared constant rather than a second hand-copy
    # of the expression.
    #
    # == Why the totals are the AREA's and not the run's
    #
    # The two `SUM(...) OVER ()` windows here are narrowed by the same predicate the rows are, so they
    # count what each run recorded IN THIS AREA — which is the denominator this panel's caption is
    # spent on and is deliberately not the figure the parent read returns under the same name. The
    # parent compares whole runs and its windows are whole runs'; this compares one area and its
    # windows are that area's. A caller that needs "did this run write per-example rows at all" must
    # ask the parent, and `SpecDirectoryFileGrowth` does exactly that rather than reading it off here
    # — an area only the latest run has would otherwise report the previous run as having recorded
    # nothing, which is a true statement about the area and a false one about the run.
    #
    # == Why this needs no index of its own
    #
    # The same argument `.directory_growth_between` makes, unchanged by the extra predicate: it
    # narrows on `test_run_id` — an `IN` list of two, served by
    # `index_spec_observations_on_test_run_id` — and the area predicate is an EXPRESSION that no index
    # can serve and that therefore decides nothing about the access path. It only ever removes rows
    # from a scan that was already happening. The grouping is on a plain column here rather than on an
    # expression, which is if anything the easier of the two shapes.
    #
    # @return [Array<Array>] `[spec_file_path, previous_count, latest_count, file_count,
    #   previous_recorded, latest_recorded]` per file, ranked by absolute movement with a path
    #   tiebreak. The last three are the same figures on every row: how many files the two runs
    #   touched in this area between them, and how many rows each run recorded in it — all three
    #   counted before the `LIMIT`, so a capped list cannot disagree with the sentence describing it.
    def file_growth_between(test_run, previous_test_run, directory,
                                 limit: SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
      latest = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", test_run.id])
      previous = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", previous_test_run.id])

      where(test_run_id: [test_run.id, previous_test_run.id])
        .where(sanitize_sql_array(["#{DIRECTORY_EXPRESSION} = ?", directory]))
        .group(:spec_file_path)
        .order(Arel.sql("ABS(#{latest} - #{previous}) DESC"), spec_file_path: :asc)
        .limit(limit)
        .pluck(Arel.sql("spec_file_path"), Arel.sql(previous), Arel.sql(latest),
               Arel.sql("COUNT(*) OVER ()"),
               Arel.sql("SUM(#{previous}) OVER ()"), Arel.sql("SUM(#{latest}) OVER ()"))
    end

    # How each code AREA's summed example DURATION moved between two runs — the same two runs and the
    # same areas as `.directory_growth_between` above, ranked by an independent quantity.
    #
    # == Why this is a sibling of that read and not a column added to it
    #
    # An area where somebody made an existing spec slow adds no examples, so its `ABS(latest_count -
    # previous_count)` is 0: it sorts last in that read and falls off its `LIMIT` entirely. The area
    # is not a row missing a column on that panel — it is not on that panel at all. And the two
    # motions are independent in both directions: splitting one slow spec into four fast ones is `+3`
    # examples and *less* time; adding a `sleep` to a shared `before` is `0` examples and minutes.
    #
    # A ranking by one quantity cannot also be a ranking by the other, which is why `SpecFileDurations`
    # and `SlowestExamples` are two objects over one run's rows for this same reason. Widening the
    # count read would silently re-rank a shipped panel; this adds a second one.
    #
    # == What is compared, and what is NOT
    #
    # `SUM(duration_seconds)` over the rows THESE TWO RUNS wrote, per area, per side. Never
    # `test_runs.duration_seconds`: that is a run's wall clock, a MAX over shard reports, and it has
    # no area grain at all. Like the count read beside it this compares POPULATIONS — it sums each
    # side's rows and subtracts two numbers — and pairs no example with any other example, so nothing
    # here asserts that a given test is the same test. A future edit that joins these runs on
    # `example_id` has left what this method is allowed to say.
    #
    # == A NULL sum is not a zero, and that decides the ranking
    #
    # `duration_seconds` is nullable by design (`Ingest::ObservationRecorder` writes `result&.run_time`),
    # so `SUM` over an area none of whose examples were timed is SQL NULL — and so is the subtraction
    # of a NULL, so the whole ordering key for such an area is NULL. `DESC` alone is NULLS FIRST,
    # which would name the area nobody MEASURED the biggest mover in the suite and put it at the head
    # of a panel about slowdowns. `NULLS LAST`, for the reason `.directory_durations_in` needs it one
    # method up. The caller renders the sums through `.humanized_duration`, the one seam that spells
    # an unmeasured total "not reported" rather than "0.00s".
    #
    # == Four counts per row, so every sum states what it was summed over
    #
    # `SUM` skips NULLs silently, so an area whose examples were half untimed reports a total covering
    # half of it — and at THIS grain that has to hold on both sides at once, because an area that
    # "got faster" between two runs may only have stopped reporting timings. So each side carries
    # both its recorded count and its TIMED count, and the two window totals of each say the same
    # thing about the runs as wholes: a run whose client sent no durations at all must read as "this
    # run reported no timings" and never as "every area lost all its time".
    #
    # Window totals over both sides, counted BEFORE the `LIMIT` (`... OVER ()` runs after `GROUP BY`
    # and before `LIMIT`), so a caption built on them cannot describe a different row set from the
    # table under it — the rule `.directory_growth_between` states above and `SpecFileDurations`
    # states first.
    #
    # == Why this needs no index of its own
    #
    # Verbatim the argument at `.directory_growth_between`: it narrows on `test_run_id` (an `IN` list
    # of two) and groups on an EXPRESSION, and only the narrowing decides the access path. The
    # `FILTER` aggregates and window totals are expressions over rows that scan already reads and add
    # no scan of their own. The one honest difference from the count read is that `SUM(duration_seconds)`
    # projects a column outside `index_spec_observations_on_test_run_id_and_spec_file_path`, so this
    # can never be an `Index Only Scan` — neither can `.directory_durations_in`, and
    # spec/models/spec_observation_spec.rb records that tradeoff for both.
    #
    # @return [Array<Array>] `[directory, previous_seconds, latest_seconds, previous_recorded,
    #   latest_recorded, previous_timed, latest_timed, directory_count, previous_recorded_total,
    #   latest_recorded_total, previous_timed_total, latest_timed_total]` per directory, ranked by
    #   absolute movement in seconds. Either `_seconds` is nil where that side timed nothing in that
    #   area. The last five are the same figures on every row, all counted before the `LIMIT`.
    def directory_runtime_growth_between(test_run, previous_test_run,
                                              limit: RETIMED_DIRECTORIES_LIMIT)
      latest_seconds = sanitize_sql_array(["SUM(duration_seconds) FILTER (WHERE test_run_id = ?)", test_run.id])
      previous_seconds = sanitize_sql_array(["SUM(duration_seconds) FILTER (WHERE test_run_id = ?)",
                                             previous_test_run.id])
      latest_recorded = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", test_run.id])
      previous_recorded = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", previous_test_run.id])
      latest_timed = sanitize_sql_array(["COUNT(duration_seconds) FILTER (WHERE test_run_id = ?)", test_run.id])
      previous_timed = sanitize_sql_array(["COUNT(duration_seconds) FILTER (WHERE test_run_id = ?)",
                                           previous_test_run.id])

      where(test_run_id: [test_run.id, previous_test_run.id])
        .group(Arel.sql(DIRECTORY_EXPRESSION))
        .order(Arel.sql("ABS(#{latest_seconds} - #{previous_seconds}) DESC NULLS LAST"),
               Arel.sql("#{DIRECTORY_EXPRESSION} ASC"))
        .limit(limit)
        .pluck(Arel.sql(DIRECTORY_EXPRESSION), Arel.sql(previous_seconds), Arel.sql(latest_seconds),
               Arel.sql(previous_recorded), Arel.sql(latest_recorded),
               Arel.sql(previous_timed), Arel.sql(latest_timed),
               Arel.sql("COUNT(*) OVER ()"),
               Arel.sql("SUM(#{previous_recorded}) OVER ()"), Arel.sql("SUM(#{latest_recorded}) OVER ()"),
               Arel.sql("SUM(#{previous_timed}) OVER ()"), Arel.sql("SUM(#{latest_timed}) OVER ()"))
    end

    # How each spec FILE of ONE area's summed example DURATION moved between two runs — the read above
    # at one grain down, and the last of the four {area,file} × {count,runtime} comparisons this model
    # serves.
    #
    # It is exactly `.directory_runtime_growth_between`'s SELECT LIST over `.file_growth_between`'s
    # GROUPING AND NARROW, and it is written out rather than parameterised for the reason those two
    # are separate methods in the first place: the grain decides the grouping, the ordering expression
    # and the window totals' meaning all at once, and a method taking "group by this or that" would be
    # one read with a branch in it standing where two reads are.
    #
    # == What this answers that no other read can
    #
    # `.directory_runtime_growth_between` names the ten AREAS whose time moved most and then dead-ends
    # on the only question a row like `spec/models 120s → 210s` provokes — WHICH FILE DID THAT. The
    # count-grain drill-in beside it cannot answer it: `.file_growth_between` measures no durations at
    # all, and a file where somebody made an existing example slow adds zero examples, so its
    # `ABS(latest_count - previous_count)` is `0` and it sorts last there and falls off the cap. The
    # two rankings are independent in both directions at this grain exactly as they are one grain up.
    #
    # `.files_in_directory` is the other neighbour and it stops one RUN short: it carries per-file
    # `SUM(duration_seconds)` for ONE run, so it holds this run's per-file seconds and never the
    # previous run's. The subtraction exists nowhere else.
    #
    # == It compares populations; it matches no tests
    #
    # The premise every read in this family stands on, unchanged by the grain: this sums each file's
    # rows in each run and subtracts two numbers. No `example_id` crosses the run boundary and no
    # example is paired with another example — an edit that joins these runs on `example_id` in order
    # to say "this test got slower" has left what this method is allowed to say, whatever the numbers
    # come out as.
    #
    # == The narrow is an EQUALITY, and it is the SAME narrow the count drill-in takes
    #
    # Through `DIRECTORY_EXPRESSION` and `= ?`, never a prefix `LIKE` — `.file_growth_between` carries
    # that argument in full, including why the two reads must share the expression rather than
    # hand-copy it. It matters once more here than it does there, because one `?spec_directory=` now
    # opens THREE blocks: two reads answering one ask through two definitions of what an area IS would
    # list a file's growth beside a panel calling the area empty, on one click.
    #
    # == A NULL sum is not a zero, and that decides the ranking
    #
    # `.directory_runtime_growth_between`'s rule at one grain finer, and the finer grain is where it
    # bites hardest: `duration_seconds` is nullable by design, so `SUM` over a file none of whose
    # examples were timed is SQL NULL, and so is the subtraction — the whole ordering key for such a
    # file is NULL. `DESC` alone is NULLS FIRST, which would name the file nobody MEASURED the biggest
    # mover in the area and put it at the head of a list about slowdowns. Hence `NULLS LAST`, and
    # hence the caller renders both sums through `.humanized_duration` rather than formatting them.
    #
    # == Four counts per row, so every sum states what it was summed over
    #
    # Verbatim the parent read's reason, and the population it is stated over is this AREA's rather
    # than the run's. `SUM` skips NULLs silently, so a file half of whose examples were untimed
    # reports a total covering half of it — and at this grain that has to hold on both sides at once,
    # because a file that "got faster" may only have stopped reporting timings. So each side carries
    # both its recorded count and its TIMED count.
    #
    # == Why the totals are the AREA's and not the run's
    #
    # The five `... OVER ()` windows are narrowed by the same predicate the rows are, so they count
    # what each run recorded and timed IN THIS AREA. Deliberately NOT the figures the parent read
    # returns under the same names, which are whole-run totals — `.file_growth_between` states the
    # hazard in full, and it is sharper here because there are twice as many of them: a caller that
    # needs "did this run report timings AT ALL" must ask the parent, since an area only the latest
    # run timed would otherwise report the previous run as having timed nothing anywhere, which is a
    # true statement about the area and a false one about the run. `SpecDirectoryFileRuntimeGrowth`
    # asks the parent, and reads none of its nine refusals off these figures.
    #
    # Counted BEFORE the `LIMIT` (`... OVER ()` runs after `GROUP BY` and before `LIMIT`), so a
    # caption built on them cannot describe a different row set from the table under it.
    #
    # == Why this needs no index of its own
    #
    # The argument `.file_growth_between` and `.directory_runtime_growth_between` both make, and this
    # read inherits both halves: it narrows on `test_run_id` — an `IN` list of two, served by
    # `index_spec_observations_on_test_run_id` — and the area predicate is an EXPRESSION no index can
    # serve, which therefore decides nothing about the access path and only ever removes rows from a
    # scan that was already happening. The grouping is on a plain column. As with every read that sums
    # durations, `SUM(duration_seconds)` projects a column outside
    # `index_spec_observations_on_test_run_id_and_spec_file_path`, so this can never be an
    # `Index Only Scan`; spec/models/spec_observation_spec.rb records that tradeoff here as it does
    # for its two parents.
    #
    # @return [Array<Array>] `[spec_file_path, previous_seconds, latest_seconds, previous_recorded,
    #   latest_recorded, previous_timed, latest_timed, file_count, previous_recorded_total,
    #   latest_recorded_total, previous_timed_total, latest_timed_total]` per file, ranked by absolute
    #   movement in seconds with a path tiebreak. Either `_seconds` is nil where that side timed
    #   nothing in that file. The last five are the same figures on every row — this AREA's — all
    #   counted before the `LIMIT`.
    def file_runtime_growth_between(test_run, previous_test_run, directory,
                                         limit: SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT)
      latest_seconds = sanitize_sql_array(["SUM(duration_seconds) FILTER (WHERE test_run_id = ?)", test_run.id])
      previous_seconds = sanitize_sql_array(["SUM(duration_seconds) FILTER (WHERE test_run_id = ?)",
                                             previous_test_run.id])
      latest_recorded = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", test_run.id])
      previous_recorded = sanitize_sql_array(["COUNT(*) FILTER (WHERE test_run_id = ?)", previous_test_run.id])
      latest_timed = sanitize_sql_array(["COUNT(duration_seconds) FILTER (WHERE test_run_id = ?)", test_run.id])
      previous_timed = sanitize_sql_array(["COUNT(duration_seconds) FILTER (WHERE test_run_id = ?)",
                                           previous_test_run.id])

      where(test_run_id: [test_run.id, previous_test_run.id])
        .where(sanitize_sql_array(["#{DIRECTORY_EXPRESSION} = ?", directory]))
        .group(:spec_file_path)
        .order(Arel.sql("ABS(#{latest_seconds} - #{previous_seconds}) DESC NULLS LAST"), spec_file_path: :asc)
        .limit(limit)
        .pluck(Arel.sql("spec_file_path"), Arel.sql(previous_seconds), Arel.sql(latest_seconds),
               Arel.sql(previous_recorded), Arel.sql(latest_recorded),
               Arel.sql(previous_timed), Arel.sql(latest_timed),
               Arel.sql("COUNT(*) OVER ()"),
               Arel.sql("SUM(#{previous_recorded}) OVER ()"), Arel.sql("SUM(#{latest_recorded}) OVER ()"),
               Arel.sql("SUM(#{previous_timed}) OVER ()"), Arel.sql("SUM(#{latest_timed}) OVER ()"))
    end
  end
end
