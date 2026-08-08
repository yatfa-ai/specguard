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

  # `[recorded, timed]` for one run — how many rows it wrote here, and how many of those carried a
  # duration — in a single round trip, because a surface that ranks rows has to state what it
  # ranked over and two separate COUNTs would be two trips for one sentence.
  #
  # `COUNT(duration_seconds)` counts non-nulls, which is exactly the population `.timed` selects,
  # so the caption cannot describe a different row set from the one the ranking scanned.
  #
  # Deliberately NOT `TestRun#total_specs_count`. That figure is re-derived by SUM over
  # `test_run_shards` and the class comment above is explicit that nothing here re-derives it; the
  # two can legitimately disagree, since `Ingest::ObservationRecorder#record` writes a row count
  # that is *"not always `specs.size`"*. Coverage of a ranking is a fact about the rows ranked.
  def self.timing_coverage_in(test_run)
    where(test_run_id: test_run.id).pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(duration_seconds)"))
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
  # second round trip for one clause of one sentence — the objection `.timing_coverage_in` answers.
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
end
