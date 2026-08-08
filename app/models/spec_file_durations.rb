# frozen_string_literal: true

# Where ONE run's wall clock went, rolled up by spec file — together with the coverage the surface
# listing it has to state.
#
# The sibling of `SlowestExamples`, and deliberately not a variant of it. That panel answers
# "which individual tests are slow"; this one answers "which FILES the run spent its time in",
# and at the roadmap's 20,000-example design point the second is not derivable from the first: a
# top-ten ranked by individual cost shows 0.05% of the suite, and a file holding 400 examples at
# 50ms each is twenty seconds of the run that is structurally incapable of appearing in it.
#
# == Why the list and its captions are one object
#
# `SlowestExamples` states the rule and it is the same rule here: a caption is a claim ABOUT the
# list. "4 of 12 examples in this file reported a timing" is only true if those two figures were
# counted off the same run's same rows the total was summed over. Fetched separately they are two
# things that agree today with no structural reason to keep agreeing.
#
# It stores no figure of its own. Every number on the panel comes back from
# `SpecObservation.file_durations_in` — one grouped aggregate, one round trip, constant in the
# size of the suite.
#
# == The denominator is the rows, not the suite size
#
# Deliberately not `TestRun#total_specs_count`, for the reason `SlowestExamples` gives and
# `SpecObservation`'s class comment states first: that figure is re-derived by SUM over
# `test_run_shards`, and `Ingest::ObservationRecorder#record` returns a row count *"not always
# `specs.size`"*, so the two can legitimately differ. There is no by-file counter anywhere else to
# borrow in any case — the per-file denominator only exists in these rows.
#
# == What a partial file means, and why every row carries its own coverage
#
# `SUM` skips NULLs silently. Excluding untimed rows is not an option at this grain the way it is
# for a ranking of examples, because exclusion changes each surviving group's own population: a
# file whose examples were half untimed reports a total covering half of it, and a file none of
# whose examples were timed reports SQL NULL. So each row states how many of its examples reported
# a timing, and a row with none of them renders "not reported" rather than a zero it did not
# measure — `SpecObservation.humanized_duration` is the one seam that decides that, at both grains.
class SpecFileDurations
  def self.for(test_run, limit: SpecObservation::HEAVIEST_FILES_LIMIT)
    rows = SpecObservation.file_durations_in(test_run, limit: limit).map do |path, total, recorded, timed|
      Row.new(path: path, total_seconds: total, recorded_count: recorded.to_i, timed_count: timed.to_i)
    end

    new(rows: rows)
  end

  def initialize(rows:)
    @rows = rows
  end

  # The rollup, heaviest first. Never longer than the limit it was built with.
  attr_reader :rows

  # Whether this run recorded per-example rows AT ALL — the question that decides whether the
  # surface has anything to say. A group exists here if and only if a row exists, so this is `rows`
  # being non-empty and needs no separate count: the aggregate cannot return a file the run wrote
  # nothing for, and cannot omit one it did.
  #
  # A run ingested before those rows existed, or one whose client sends no per-example detail, has
  # no per-file grain to disclose. The `recorded?` / `any_timed?` split is `SlowestExamples`'s
  # `recorded?` / `any?` split: "this run reported no tests" and "this run reported no timings" are
  # different facts and the panel says them differently.
  def recorded? = rows.any?

  # At least one file has a total to rank. False for a run that recorded examples and timed none of
  # them — every group's SUM is NULL, so there is a list of files but no ranking, and a column of
  # "not reported" under a heading that promises "heaviest first" would be a ranking of nothing.
  def any_timed? = rows.any?(&:timed?)

  # Every listed file reported a timing for every one of its examples — the state worth SAYING
  # rather than leaving a reader to compare each row's two figures to reach it.
  def complete? = recorded? && rows.all?(&:complete?)

  # One spec file's share of one run's wall clock, and what that share was measured over.
  Row = Struct.new(:path, :total_seconds, :recorded_count, :timed_count, keyword_init: true) do
    # This file has a measured total. False when every one of its examples went untimed, which is
    # SQL NULL out of the aggregate and stays nil all the way to the cell.
    def timed? = !total_seconds.nil?

    def complete? = timed_count == recorded_count

    def untimed_count = recorded_count - timed_count

    # The total, rendered — through the same seam one example's duration is rendered through, so a
    # file total and an example measurement cannot disagree about how a duration is spelled, and an
    # unmeasured file says "not reported" rather than "0.00s".
    def duration_label = SpecObservation.humanized_duration(total_seconds)

    # How much of the file this total covers, always as a fraction and never as a bare count. "12"
    # in a column of "4 of 12" reads as twelve of something unstated; the denominator is the point
    # of the column, and a complete file has to be visibly complete rather than merely unannotated.
    def coverage_label = "#{timed_count} of #{recorded_count}"
  end
end
