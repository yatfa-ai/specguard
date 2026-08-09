# frozen_string_literal: true

# ONE code area's spec files in ONE run — the rows behind a single line of the "Heaviest spec
# directories" panel, together with the coverage the surface listing them has to state.
#
# The middle rung of the drill-in, and the one that was missing. `SpecDirectoryDurations` names the
# ten areas the run spent most of its wall clock in; `SpecFileExamples` lists one file's examples.
# Between them there was nothing, and the by-file rollup could not stand in: it is a capped ten too,
# and `SpecDirectoryDurations`' own class comment says why that makes it the wrong way in — "a
# directory holding forty files at two seconds each is eighty seconds of the run with not one of its
# rows in that list". The heaviest AREA is exactly the one whose files a by-file top ten cannot
# show, so until this existed a reader who found it had found the end of the road rather than the
# start of one.
#
# == Why the list and its captions are one object
#
# `SpecFileExamples` states the rule one rung down and `SpecDirectoryDurations` states it one rung
# up, unchanged by the grain: a caption is a claim ABOUT the list. "12 of the 30 files this run
# recorded in this area, covering 140 of its 610 examples" is only true if all four figures were
# counted off the same run's same rows the list was taken from. Fetched separately they are figures
# that agree today with no structural reason to keep agreeing.
#
# It derives no figure of its own and takes no second query for them: the area's file count and its
# example counts ride back on the listed rows as windows — see `SpecObservation.files_in_directory`
# for why all three are available in the one aggregate.
#
# == The denominator is this area's rows, not the run's and not the suite's
#
# For the reason every object at these grains gives: `TestRun#total_specs_count` is re-derived by
# SUM over `test_run_shards` and `Ingest::ObservationRecorder#record` returns a row count *"not
# always `specs.size`"*, so the two can legitimately differ — and there is no per-area counter
# anywhere else to borrow in any case. An area's population exists only in these rows.
#
# == At one depth, like the rollup it opens out of
#
# The area is compared for EQUALITY, so `spec/models/orders` is not part of `spec/models` here any
# more than it is part of it in the panel above — every row sits at the same depth as its own file
# and these totals partition the area the way the rollup's partition the run.
# `SpecObservation.files_in_directory` holds the argument, including why a prefix `LIKE` would be a
# different feature.
#
# == An area the run recorded nothing for is not an error
#
# `?spec_directory=` is a URL a reader types, edits and bookmarks, and a run that did not touch the
# area they ask for is an ordinary answer rather than a malformed request: a stale bookmark, a
# directory deleted since, a path with a typo in it. `.for` returns an object with no rows and the
# surface says so — the same shape `SpecFileExamples` answers one rung down.
class SpecDirectoryFiles
  def self.for(test_run, path, limit: SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
    tuples = SpecObservation.files_in_directory(test_run, path, limit: limit)
    rows = tuples.map do |file_path, total, recorded, timed, *|
      Row.new(path: file_path, total_seconds: total, recorded_count: recorded.to_i,
              timed_count: timed.to_i)
    end

    # Off any row, because the three windows carry the same figures on all of them; `to_i` over the
    # nil of an empty read, where zero is the honest count.
    _path, _total, _recorded, _timed, file_count, area_recorded, area_timed = tuples.first

    new(path: path, rows: rows, file_count: file_count.to_i,
        recorded_count: area_recorded.to_i, timed_count: area_timed.to_i)
  end

  def initialize(path:, rows:, file_count:, recorded_count:, timed_count:)
    @path = path
    @rows = rows
    @file_count = file_count
    @recorded_count = recorded_count
    @timed_count = timed_count
  end

  # The area that was asked for, as it was asked for. Held even when nothing came back, because the
  # empty state has to name it — "no spec files" without a subject is a sentence about nothing.
  attr_reader :path

  # This area's spec files, heaviest first, its untimed files last. Never longer than the limit it
  # was built with.
  attr_reader :rows

  # How many spec files this run recorded in this area IN TOTAL — the denominator `rows.size` is
  # not. The list is capped, so its own length answers "how many rows am I looking at" and nothing
  # else, and a caption built on it reads "the files this area holds" on an area holding three times
  # as many. Counted before the cap, in the same pass as the totals.
  attr_reader :file_count

  # How many EXAMPLES this run recorded in this area, and how many of them carried a duration —
  # both counted over the whole area rather than over the files that fit on the page, which on a
  # truncated area are different populations. The figures the panel's coverage sentence is spent on.
  attr_reader :recorded_count, :timed_count

  # Whether this run recorded any rows for this area AT ALL — the question that decides whether the
  # panel has a list or an empty state. A group exists here if and only if the run wrote a row for a
  # file in the area, so this is `rows` being non-empty and needs no separate count.
  def recorded? = rows.any?

  # At least one of this area's examples reported a duration. Distinct from `#recorded?` for the
  # reason every panel at every grain here keeps the two apart: "this run recorded nothing here" and
  # "this run measured nothing here" are different facts, and only the first is an empty area. A
  # list still renders for the second — the files exist and their example counts are worth reading —
  # but nothing in it is ranked, and a caption promising "heaviest first" over it would be ranking
  # nothing.
  #
  # Counted over the AREA rather than off `rows.any?(&:timed?)`, which the two rollups above use:
  # this list is capped over a population the reader cannot see all of, so the honest answer to
  # "did this area measure anything" is the area's, not the page's.
  def any_timed? = timed_count.positive?

  # Every example this run recorded in this area reported a duration — the state worth SAYING rather
  # than leaving a reader to compare two numbers to reach.
  def complete? = recorded? && timed_count == recorded_count

  # There are spec files in this area the list does not show. The state the caption has to SAY
  # rather than leave a reader to infer from a list whose length happens to equal a limit they
  # cannot see — the argument `SpecDirectoryDurations#truncated?` makes one rung up, where the
  # population is areas and here is files.
  def truncated? = file_count > rows.size

  # How much of the AREA the listed durations cover, always as a fraction and never as a bare count
  # — the spelling `SpecDirectoryDurations::Row#coverage_label` fixed for the panel this drills out
  # of, so the same claim about the same area reads the same way on both.
  def coverage_label = "#{timed_count} of #{recorded_count}"

  # One spec file's share of one area's wall clock, and what that share was measured over. The same
  # four fields `SpecFileDurations::Row` carries, because it is the same claim about the same grain
  # — narrowed to one area rather than ranked across the run.
  Row = Struct.new(:path, :total_seconds, :recorded_count, :timed_count, keyword_init: true) do
    # This file has a measured total. False when every one of its examples went untimed, which is
    # SQL NULL out of the aggregate and stays nil all the way to the cell.
    def timed? = !total_seconds.nil?

    def complete? = timed_count == recorded_count

    # The total, rendered — through the same seam one example's duration, one file's total and one
    # area's total are rendered through, so no two grains on this page can disagree about how a
    # duration is spelled, and an unmeasured file says "not reported" rather than "0.00s".
    def duration_label = SpecObservation.humanized_duration(total_seconds)

    # How much of the file this total covers, always as a fraction and never as a bare count. "40"
    # in a column of "12 of 40" reads as forty of something unstated; the denominator is the point
    # of the column, and a complete file has to be visibly complete rather than merely unannotated.
    def coverage_label = "#{timed_count} of #{recorded_count}"
  end
end
