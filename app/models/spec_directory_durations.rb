# frozen_string_literal: true

# Where ONE run's wall clock went, rolled up by code AREA — the immediate parent directory of the
# file that ran each example — together with the coverage the surface listing it has to state.
#
# The sibling of `SpecFileDurations` one rung up, and deliberately not a variant of it. That panel
# answers "which FILES the run spent its time in"; this one answers "which AREAS", and the second
# is not derivable from the first: a by-file top ten shows ten files, and a directory holding forty
# files at two seconds each is eighty seconds of the run with not one of its rows in that list.
# Concentration re-concentrates at every rung, which is why each rung is summed rather than read
# off the one below it.
#
# It is also not a shard rollup. `TestRun#shard_durations` answers "which CI partition ran long"
# and its own comment is explicit that **a shard is not a code area** — partitions are arbitrary
# with respect to directory structure. The two grains cannot stand in for each other.
#
# == Why the list and its captions are one object
#
# `SpecFileDurations` states the rule and it is the same rule here, unchanged by the grain: a
# caption is a claim ABOUT the list, so "8 of 20 examples in this area reported a timing" is only
# true if both figures were counted off the same run's same rows the total was summed over. This
# object derives no figure of its own — every number on the panel comes back from
# `SpecObservation.directory_durations_in`: one grouped aggregate, one round trip, constant in the
# size of the suite.
#
# == The denominator is the rows, not the suite size
#
# Deliberately not `TestRun#total_specs_count`, for the reason `SpecFileDurations` and
# `SpecObservation`'s class comment give: that figure is re-derived by SUM over `test_run_shards`,
# and `Ingest::ObservationRecorder#record` returns a row count *"not always `specs.size`"*, so the
# two can legitimately differ. There is no by-directory counter anywhere else to borrow in any
# case — the per-area denominator only exists in these rows.
#
# == What a partial area means, and why every row carries its own coverage
#
# `SUM` skips NULLs silently, and the argument is `SpecFileDurations`' one grain up, where it
# costs more: excluding untimed rows changes each surviving group's own population, and an area is
# a bigger population than a file. An area whose examples were half untimed reports a total
# covering half of it, and an area none of whose examples were timed reports SQL NULL. So each row
# states how many of its examples reported a timing, and a row with none of them renders "not
# reported" rather than a zero it did not measure — `SpecObservation.humanized_duration` is the one
# seam that decides that, at every grain.
class SpecDirectoryDurations
  def self.for(test_run, limit: SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
    tuples = SpecObservation.directory_durations_in(test_run, limit: limit)
    rows = tuples.map do |path, total, recorded, timed, _directory_count|
      Row.new(path: path, total_seconds: total, recorded_count: recorded.to_i, timed_count: timed.to_i)
    end

    # Off any row, because the window carries the same total on all of them; `to_i` on the nil of
    # an empty read, where "no directories" is the honest count.
    new(rows: rows, directory_count: tuples.first&.last.to_i)
  end

  def initialize(rows:, directory_count:)
    @rows = rows
    @directory_count = directory_count
  end

  # The rollup, heaviest first. Never longer than the limit it was built with.
  attr_reader :rows

  # How many directories the run touched IN TOTAL — the denominator `rows.size` is not. The list is
  # capped, so its own length answers "how many rows am I looking at" and nothing else, and a
  # caption built on it reads "the 10 areas the run spent the most wall clock in" on a run that
  # touched eighty: a truncated list silently wearing the shape of a complete one, which is the
  # reading this whole panel exists to refuse one grain down. Counted in the same pass as the
  # totals, so it cannot describe a different row set from the one listed.
  attr_reader :directory_count

  # There are areas this run touched that the list does not show. The state the caption has to SAY
  # rather than leave a reader to infer from a list whose length happens to equal a limit they
  # cannot see — the same reason `#complete?` exists one column over.
  def truncated? = directory_count > rows.size

  # Whether this run recorded per-example rows AT ALL — the question that decides whether the
  # surface has anything to say. A group exists here if and only if a row exists, so this is `rows`
  # being non-empty and needs no separate count: the aggregate cannot return an area the run wrote
  # nothing for, and cannot omit one it did.
  #
  # A run ingested before those rows existed, or one whose client sends no per-example detail, has
  # no per-area grain to disclose. The `recorded?` / `any_timed?` split is `SpecFileDurations`', and
  # `SlowestExamples`' before it: "this run reported no tests" and "this run reported no timings"
  # are different facts and the panel says them differently.
  def recorded? = rows.any?

  # At least one area has a total to rank. False for a run that recorded examples and timed none of
  # them — every group's SUM is NULL, so there is a list of areas but no ranking, and a column of
  # "not reported" under a heading that promises "heaviest first" would be a ranking of nothing.
  def any_timed? = rows.any?(&:timed?)

  # Every listed area reported a timing for every one of its examples — the state worth SAYING
  # rather than leaving a reader to compare each row's two figures to reach it.
  def complete? = recorded? && rows.all?(&:complete?)

  # One directory's share of one run's wall clock, and what that share was measured over.
  Row = Struct.new(:path, :total_seconds, :recorded_count, :timed_count, keyword_init: true) do
    # This area has a measured total. False when every one of its examples went untimed, which is
    # SQL NULL out of the aggregate and stays nil all the way to the cell.
    def timed? = !total_seconds.nil?

    def complete? = timed_count == recorded_count

    # The total, rendered — through the same seam one example's duration and one file's total are
    # rendered through, so no two grains on this page can disagree about how a duration is spelled,
    # and an unmeasured area says "not reported" rather than "0.00s".
    def duration_label = SpecObservation.humanized_duration(total_seconds)

    # How much of the area this total covers, always as a fraction and never as a bare count. "40"
    # in a column of "12 of 40" reads as forty of something unstated; the denominator is the point
    # of the column, and a complete area has to be visibly complete rather than merely unannotated.
    def coverage_label = "#{timed_count} of #{recorded_count}"
  end
end
