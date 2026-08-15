# frozen_string_literal: true

# ONE spec file's examples in ONE run — the rows behind a single line of the "Heaviest spec files"
# panel, together with the coverage the surface listing them has to state.
#
# The rung below `SpecFileDurations`, and the first read in this application that narrows to a file
# rather than grouping by one. That panel says `spec/models/order_spec.rb` cost six minutes across
# 340 examples; until this existed, writing SQL was the only way to learn WHICH 340. Every ranked
# surface on the page is a capped ten, so at the roadmap's 20,000-example design point a reader who
# has found the heavy file has found the end of the road rather than the start of one.
#
# == Why the list and its captions are one object
#
# `SlowestExamples` states the rule and `SpecFileDurations` repeats it: a caption is a claim ABOUT
# the list. "50 of the 340 examples this run recorded in this file, of which 312 reported a
# duration" is only true if all three figures were counted off the same run's same rows the list
# was taken from. Fetched separately they are figures that agree today with no structural reason to
# keep agreeing.
#
# It derives no figure of its own, and here it does not even take a second query for them: the
# file's recorded and timed counts ride back on the listed rows as window counts — see
# `SpecObservation::FILE_POPULATION_COUNTS` for why that is available at this grain and was not at
# the one above.
#
# ⚠️ This class's prose states this panel's page capacity in THREE places — the worked caption
# opening this section, the truncation argument at `#shown_timed_count`, and the tail test at
# `#lists_untimed?`. All three are derived from `SpecObservation::FILE_EXAMPLES_LIMIT`, not from
# each other and not from any of these sentences: that constant is the figure's one owner, and a
# resize rots all three at once. Re-resolve it before touching any of them — a correction pass that
# trusts the adjacent prose over the constant propagates the wrong number instead of fixing it. One
# of the three was born wrong rather than drifting later: it shipped in the same commit that set
# the constant to fifty, while the other two shipped right, so the figure it carried was never a
# cap this panel has held. A pass that had trusted that sentence would have spread a number that
# was never correct, not restored one that had gone stale.
#
# == The denominator is this file's rows, not the run's and not the suite's
#
# For the reason `SlowestExamples` and `SpecFileDurations` both give: `TestRun#total_specs_count` is
# re-derived by SUM over `test_run_shards` and `Ingest::ObservationRecorder#record` returns a row
# count *"not always `specs.size`"*, so the two can legitimately differ — and there is no per-file
# counter anywhere else to borrow in any case. A file's population exists only in these rows.
#
# == A file the run recorded nothing for is not an error
#
# `?spec_file=` is a URL a reader types, edits and bookmarks, and a run that did not touch the file
# they ask for is an ordinary answer rather than a malformed request: a stale bookmark, a file
# deleted since, a path with a typo in it. `.for` returns an object with no rows and the surface
# says so — the same shape `#recorded?` answers one grain up.
class SpecFileExamples
  def self.for(test_run, path, limit: SpecObservation::FILE_EXAMPLES_LIMIT)
    new(path: path, rows: SpecObservation.in_file(test_run, path, limit: limit).to_a)
  end

  def initialize(path:, rows:)
    @path = path
    @rows = rows
  end

  # The file that was asked for, as it was asked for. Held even when nothing came back, because the
  # empty state has to name it — "no examples" without a subject is a sentence about nothing.
  attr_reader :path

  # This file's examples, slowest first, its untimed rows last. Never longer than the limit it was
  # built with.
  attr_reader :rows

  # How many examples this run recorded in this file IN TOTAL, and how many of them carried a
  # duration — both counted before the cap, so neither describes the listed head rather than the
  # file.
  #
  # Read off any row, because the windows carry the same two figures on all of them; `to_i` over the
  # nil of an empty read, where zero is the honest count. The same "read it off whichever row you
  # have" shape `SpecFileDurations` uses for `file_count`, one grain up.
  def recorded_count = window_count("file_recorded_count")

  def timed_count = window_count("file_timed_count")

  # Whether this run recorded any rows for this file AT ALL — the question that decides whether the
  # panel has a list or an empty state. A row exists here if and only if the run wrote one for the
  # file, so this is `rows` being non-empty and needs no separate count.
  def recorded? = rows.any?

  # Rows this run recorded here and did not time. Not a defect and not a gap to paper over: an
  # example that never ran has no duration to report, so the nil is a faithful record — see
  # `Ingest::ObservationRecorder#attributes`. They are LISTED rather than excluded, at the end of
  # the list rather than the head of it; this is how many of them the FILE holds.
  def untimed_count = recorded_count - timed_count

  # == What is actually on the page, as against what the file holds
  #
  # The three figures above are windows counted before the cap, which is what makes them true of
  # the FILE. That is the whole point of them and it is also the trap: on a truncated file they
  # describe rows a reader cannot see, and a caption that spends them as though they were the list
  # says "the other 300 sit at the end of this list" over a page holding fifty of them.
  #
  # These two are counted off the LOADED ROWS instead — the ones rendered — so a caption can say
  # how much of each population it is showing. Counted rather than derived from the ordering: it is
  # true that `NULLS LAST` puts every timed row ahead of every untimed one and therefore that a
  # listed untimed row implies every timed row is listed, but a count off the rows on hand is the
  # same cost and stays right if the ordering is ever revisited.
  def shown_timed_count = rows.count { |row| !row.duration_seconds.nil? }

  def shown_untimed_count = rows.size - shown_timed_count

  # Untimed examples this file holds that the cap left off the page ENTIRELY — not at the end of
  # the list, not anywhere in it. The figure that has to be said out loud, because the sentence a
  # reader would otherwise be given ("the other 300 reported none and sit at the END of the list")
  # is the one shape of this panel where it is false.
  def untimed_omitted_count = untimed_count - shown_untimed_count

  # The list's tail is untimed rows. Decides whether "the 50 slowest" is a description of this page
  # or a claim about it that is false: those rows are not the slowest of anything, they are the
  # lowest-`id` rows of a population nothing ranked, and they only reach the page at all because
  # the timed rows ran out before the cap did.
  def lists_untimed? = shown_untimed_count.positive?

  # Every example this run recorded in this file reported a duration — the state worth SAYING
  # rather than leaving a reader to compare two numbers to reach.
  def complete? = recorded? && timed_count == recorded_count

  # Not one example in this file reported a duration. Distinct from `#recorded?` for the reason
  # every panel at this grain keeps the two apart: "this run recorded nothing here" and "this run
  # measured nothing here" are different facts, and only the first is an empty file. The list still
  # renders — the examples exist, they ran or failed to, and their outcomes are worth reading — but
  # nothing in it is ranked, and a caption promising "slowest first" over it would be ranking
  # nothing.
  def any_timed? = timed_count.positive?

  # There are examples in this file the list does not show. The state the caption has to SAY rather
  # than leave a reader to infer from a list whose length happens to equal a limit they cannot see
  # — the argument `SpecFileDurations#truncated?` makes one grain up, where the population is files
  # and here is examples.
  def truncated? = recorded_count > rows.size

  # How much of the file the listed durations cover — through the same seam every coverage fraction
  # on these pages is spelled through, so this caption and the `SpecFileDurations::Row` for the
  # panel it drills out of make the same claim about the same file in one spelling rather than in
  # two prose inventions that agree today.
  def coverage_label = SpecObservation.coverage_fraction(timed_count, recorded_count)

  private

  # `to_i` over `nil` twice: over the empty read that has no row to carry a window, and over the
  # attribute itself, since a count arriving as anything but an Integer must still leave the
  # captions doing arithmetic on integers.
  def window_count(attribute) = rows.first&.[](attribute).to_i
end
