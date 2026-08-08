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

  # How many spec DIRECTORIES a by-directory rollup returns. Its own constant for the reason
  # `HEAVIEST_FILES_LIMIT` gives one grain down and by the same rule: a rollup at a different grain
  # ranks a different population. One run has fewer directories than files and far fewer than
  # examples, so a suite that wants twenty files ranked has no reason to want twenty areas ranked,
  # and one number standing for both would make that a single edit nobody meant to make.
  HEAVIEST_DIRECTORIES_LIMIT = 10

  # How many spec DIRECTORIES a by-directory COMPARISON returns. Its own constant, by the same rule
  # the three above it obey and for a difference that is bigger here than any of theirs: those rank
  # ONE run's areas by what they cost, this ranks the areas of TWO runs by how far their example
  # counts MOVED. The population is the union of two runs' directories rather than one run's, and
  # the quantity ranked is a signed change rather than a total — so a suite that wants ten areas by
  # wall clock has no reason to want ten areas by movement, and one number standing for both would
  # make that a single edit nobody meant to make.
  MOVED_DIRECTORIES_LIMIT = 10

  # How many EXAMPLES a single spec file's drill-down returns. Its own constant, by the rule the
  # three above it obey and for a difference that is the reverse of theirs: those cap RANKINGS —
  # lists whose whole purpose is to show the head of a population and stop — and this caps a
  # LISTING, the rows of one file a reader has already picked out of such a ranking. A reader who
  # opened a file to get past a top ten is not served by another top ten, and one file's examples
  # are a far smaller population than the run's, so this sits well above `SLOWEST_LIMIT` and is not
  # it under another name. Named because the panel's caption reports the figure back to the reader,
  # and a sentence explaining a list's length must not be able to disagree with it.
  FILE_EXAMPLES_LIMIT = 50

  # What the drill-down's caption has to say ABOUT the rows under it, counted in the SAME read that
  # returns them — `COUNT(*) OVER ()` and `COUNT(duration_seconds) OVER ()`, which count non-nulls.
  #
  # Windows are evaluated after the WHERE and before the LIMIT, so both figures cover the whole
  # FILE however few rows come back: the cap is disclosed against the file's real population rather
  # than against itself, and the timing coverage is the file's rather than the listed head's.
  #
  # Riding on the listed rows rather than taken as a second aggregate, and that is available here
  # in a way it was not for `SlowestExamples`. That panel's ranking EXCLUDES untimed rows in the
  # WHERE clause, so no window over it could ever have counted them and its coverage had to be a
  # second read. This list excludes nothing — the file's untimed examples ARE part of what it shows
  # — so the population the caption describes is exactly the population the window sees, and one
  # round trip gives a caption that cannot come to describe a different row set from the one below
  # it. It also costs nothing: the ORDER BY is on `duration_seconds`, which no index here leads on,
  # so every one of the file's rows is read before the LIMIT can be applied whether these two
  # counters ride along or not.
  FILE_POPULATION_COUNTS = "COUNT(*) OVER () AS file_recorded_count, " \
                           "COUNT(duration_seconds) OVER () AS file_timed_count"

  # The code area a row belongs to: the IMMEDIATE PARENT directory of the including file.
  #
  # Off `spec_file_path` and never `file_path`, for the reason `#file_durations_in` states and the
  # class comment above states first — a shared example group's time has to land on the area that
  # RAN it, not on the `spec/support/` area that defines it.
  #
  # `substring(... from '^(.*)/[^/]*$')` rather than a `regexp_replace` of the trailing segment,
  # because the two differ on the row that has no directory at all. `.*` is greedy, so the capture
  # ends at the LAST separator and the parent is immediate rather than the root. A path carrying no
  # separator — a spec file sitting at the repository root — matches nothing and comes back SQL
  # NULL, which as a GROUP BY key would be an unnamed area on the panel; `COALESCE` names it `.`,
  # which is what `Pathname#dirname` calls that directory and what the reader will recognise.
  # Coalescing rather than filtering, because dropping those rows would silently understate the
  # run's wall clock at the one grain that is supposed to account for all of it.
  #
  # One constant, referenced by the GROUP BY, the ORDER BY tiebreak and the projection alike: three
  # hand-copies of one expression is three definitions of what an area IS, and Postgres would
  # happily group by one and select another.
  DIRECTORY_EXPRESSION = "COALESCE(substring(spec_file_path from '^(.*)/[^/]*$'), '.')"

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

  # ONE spec file's examples in ONE run, slowest first — the rung BELOW the rollup above, and the
  # read `index_spec_observations_on_test_run_id_and_spec_file_path` exists for. The by-file rollup
  # says `spec/models/order_spec.rb` cost six minutes across 340 examples; nothing until now could
  # say WHICH 340, at a design point where every panel on the page is a capped ten.
  #
  # == It leads with the by-file index, and must go on doing so
  #
  # `.slowest_in` is a backward scan on `index_spec_observations_on_test_run_id_and_duration_seconds`
  # and its comment calls that plan *"constant in suite size"*. Adding `spec_file_path` to THAT scan
  # would destroy exactly the property the comment claims: the scan would walk the run from its
  # slowest example downward discarding every row belonging to another file, which on a small file
  # in a 20,000-example run is most of the run to fill a page. This narrows on
  # `(test_run_id, spec_file_path)` first — an equality predicate on both columns of the composite
  # index, so the rows read are the file's and only the file's — and sorts that handful. Cost is
  # bounded by the size of the FILE, not of the suite. EXPLAIN-certified against a real planner at
  # the 20-run seed in spec/models/spec_observation_spec.rb.
  #
  # Deliberately an EQUALITY predicate and deliberately not a subtree. "Every row under
  # `spec/models/`" is a PREFIX predicate, which wants a `text_pattern_ops` index and therefore a
  # migration; this read issues none and needs none. That boundary is recorded in the same spec.
  #
  # == Untimed rows are LISTED, which is why the ordering carries `NULLS LAST`
  #
  # `scope :timed` excludes them from every RANKING because a row with nothing to compare cannot be
  # the slowest of anything. This is not a ranking of the suite; it is the file's population, and an
  # example the client never timed is part of that population — hiding it would make a file's list
  # disagree with the `recorded_count` printed above it. So the rows stay, and `duration_seconds:
  # :desc` alone would then be **NULLS FIRST** in Postgres: the examples that reported no duration
  # at the head of a list captioned "slowest first". They sort to the END instead, which is the
  # hazard `scope :timed` documents answered by the other of the two ways it names.
  #
  # `id` breaks ties, so a file whose examples tie — and a file all of whose examples went untimed,
  # where every row ties — has one stable order rather than one the planner picks afresh per
  # request.
  #
  # The projection carries `FILE_POPULATION_COUNTS`, so a caller gets the file's recorded and timed
  # counts off the same read as the rows; see that constant for why they are windows rather than a
  # second aggregate. Those two are ATTRIBUTES of the returned records rather than a separate
  # value, which makes this relation one to load and read — `SpecFileExamples` is its one caller —
  # rather than one to count or paginate further.
  def self.in_file(test_run, spec_file_path, limit: FILE_EXAMPLES_LIMIT)
    where(test_run_id: test_run.id, spec_file_path: spec_file_path)
      .select(Arel.sql("spec_observations.*, #{FILE_POPULATION_COUNTS}"))
      .order(Arel.sql("duration_seconds DESC NULLS LAST"), id: :asc)
      .limit(limit)
  end

  # Where ONE run's wall clock went, rolled up by DIRECTORY — the rung directly above the rollup
  # above, and the grain the question is usually asked in. "Which area of this suite carries the
  # time" is not answerable from a ranked list of files any more than it was from a ranked list of
  # examples: a directory holding forty files at two seconds each is eighty seconds of the run with
  # not one of its files near the head of a by-file top ten. Concentration re-concentrates one rung
  # up, and each rung has to be summed to be seen.
  #
  # Grouped on `DIRECTORY_EXPRESSION` — the immediate parent of the INCLUDING file — so a shared
  # example group's time lands on the area that ran it rather than on `spec/support`, and so the
  # areas listed partition the run rather than nesting inside one another. Depth selection and
  # drill-down trees are a different question and deliberately not this one: every row here is at
  # the same depth as its own file, so the totals are disjoint and sum to the run.
  #
  # NOT a shard. `TestRun#shard_durations` rolls a run up by CI partition and its comment is
  # explicit that "a shard is not a code area" — RSpec/Knapsack partitions are arbitrary with
  # respect to directory structure. That grain answers "which partition ran long"; this one answers
  # "which area of the codebase costs", and neither is derivable from the other.
  #
  # @return [Array<Array>] `[directory, total_seconds, recorded_count, timed_count, directory_count]`
  #   per directory, where `directory_count` is the same figure on every row: how many directories
  #   the run touched in total, before the `LIMIT`.
  #
  # == Every hazard the by-file read documents, at this grain
  #
  # The four columns, `pluck` over `.sum`, and `NULLS LAST` are all here for the reasons spelled
  # out on `.file_durations_in` above — read that comment, it is not repeated. What changes with
  # the grain is only how much each one costs when it is got wrong: an area is a bigger population
  # than a file, so an all-untimed area rendered as `0.00s` is a bigger invented measurement, and
  # `SUM(...) DESC`'s NULLS FIRST would name that area the heaviest in the suite.
  #
  # == Why this needs no index of its own
  #
  # It groups on an EXPRESSION and narrows on a COLUMN, and only the second decides the access
  # path. `where(test_run_id:)` is served by `index_spec_observations_on_test_run_id` and the
  # grouping hash-aggregates on top of it — the same plan `.file_durations_in` gets and for the
  # same reason spec/models/spec_observation_spec.rb states there: the aggregate has to touch the
  # heap for `duration_seconds` either way, so no wider index buys a whole-run grouping anything.
  # A `text_pattern_ops` index governs a prefix PREDICATE — "every row under `spec/models/`" — and
  # this read has no prefix predicate to serve. Both claims are EXPLAIN-certified at the 20-run
  # seed in that spec rather than argued for here.
  def self.directory_durations_in(test_run, limit: HEAVIEST_DIRECTORIES_LIMIT)
    where(test_run_id: test_run.id)
      .group(Arel.sql(DIRECTORY_EXPRESSION))
      .order(Arel.sql("SUM(duration_seconds) DESC NULLS LAST"), Arel.sql("#{DIRECTORY_EXPRESSION} ASC"))
      .limit(limit)
      .pluck(Arel.sql(DIRECTORY_EXPRESSION), Arel.sql("SUM(duration_seconds)"),
             Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"),
             Arel.sql("COUNT(*) OVER ()"))
  end

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
  # grouping hash-aggregates on top, which is the plan `.directory_durations_in` gets one method
  # up; two runs is twice the rows, not a different shape. EXPLAIN-certified at the 20-run seed in
  # spec/models/spec_observation_spec.rb rather than argued for here.
  #
  # @return [Array<Array>] `[directory, previous_count, latest_count, directory_count,
  #   previous_recorded, latest_recorded]` per directory, ranked by absolute movement. The last
  #   three are the same figures on every row: how many areas the two runs touched between them,
  #   and how many rows each run recorded in total — all three counted before the `LIMIT`.
  def self.directory_growth_between(test_run, previous_test_run, limit: MOVED_DIRECTORIES_LIMIT)
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
  #
  # Only the three RSpec names the producer is known to send are given a colour. Everything else —
  # an unrecognised string AND a nil — is `:neutral`, because a tone is a claim: green over a value
  # nobody validated would be this page asserting a pass it was never told about. The two neutral
  # cases are still distinguishable from each other by their text, which is what `#outcome_label`
  # is for; what they share is that neither of them is a pass.
  def outcome_tone
    case outcome
    when "failed" then :error
    when "pending" then :warning
    when "passed" then :success
    else :neutral
    end
  end
end
