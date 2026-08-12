# frozen_string_literal: true

# ONE repeated description's examples in ONE run — the rows behind a single line of the "Descriptions
# this run recorded more than once" panel, together with the coverage the surface listing them has to
# state.
#
# The rung below `RepeatedDescriptions`, and the third drill-down on this page rather than a new kind
# of thing: `SpecFileExamples` opens a file out of the by-file rollup and `SpecDirectoryFiles` opens
# an area out of the by-area one. That panel was the only ranked list on the page whose rows
# dead-ended. It says a description is carried by eight examples costing ninety seconds between them
# and names the files they ran in, and until this existed writing SQL was the only way to learn WHICH
# eight, what each cost, where each sits and how each ended.
#
# == The decision these rows exist to serve
#
# The panel above is explicit that a shared description is equally a table-driven loop, a shared
# example group, or the same test written twice, and that nothing in its rows decides which. That is
# a boundary on what the SURFACE may claim, not a reason to withhold the evidence — the reader has to
# decide, and a group's members are what they decide from. Three rows at consecutive line numbers in
# one file read as a loop; the same description at three unrelated sites reads as something else. So
# nothing here uses the word "duplicate" either, and the rows carry file, line, duration and outcome
# and no verdict of any kind.
#
# == Why the list and its captions are one object
#
# `SlowestExamples` states the rule, `SpecFileDurations` repeats it and `SpecFileExamples` repeats it
# again: a caption is a claim ABOUT the list. "25 of the 40 examples this run recorded under this
# description, of which 38 reported a duration" is only true if all three figures were counted off
# the same run's same rows the list was taken from. Fetched separately they are figures that agree
# today with no structural reason to keep agreeing.
#
# It derives no figure of its own, and here it does not even take a second query for them: the
# group's recorded and timed counts ride back on the listed rows as window counts — see
# `SpecObservation::DESCRIPTION_POPULATION_COUNTS`, which is its own constant rather than a reuse of
# the file drill-down's precisely because these windows count the DESCRIPTION'S rows.
#
# == The denominator is this description's rows, not the file's and not the run's
#
# The group's own `recorded_count` in the ranking above is the same figure counted the same way, and
# the two agree because both are `COUNT(*)` over the run's rows carrying this name. Nothing here
# borrows `TestRun#total_specs_count`, which is re-derived by SUM over `test_run_shards` and can
# legitimately differ, for the reason every panel at this grain gives. A description's population
# exists only in these rows.
#
# == A description the run recorded nothing for is not an error
#
# `?repeated_description=` is a URL a reader types, edits and bookmarks, and a run that recorded
# nothing under the description they ask for is an ordinary answer rather than a malformed request: a
# test renamed since, a description edited, a stale bookmark, a typo. `.for` returns an object with
# no rows and the surface says so — the same shape `#recorded?` answers on both siblings.
class RepeatedDescriptionExamples
  def self.for(test_run, name, limit: SpecObservation::REPEATED_DESCRIPTION_EXAMPLES_LIMIT)
    new(name: name, rows: SpecObservation.with_description(test_run, name, limit: limit).to_a)
  end

  def initialize(name:, rows:)
    @name = name
    @rows = rows
  end

  # The description that was asked for, as it was asked for. Held even when nothing came back,
  # because the empty state has to name it — "no examples" without a subject is a sentence about
  # nothing, and on this panel the subject IS a sentence somebody wrote, which is the one thing a
  # reader can check against their own suite.
  attr_reader :name

  # The examples carrying this description, slowest first, its untimed rows last. Never longer than
  # the limit it was built with.
  attr_reader :rows

  # How many examples this run recorded under this description IN TOTAL, and how many of them carried
  # a duration — both counted before the cap, so neither describes the listed head rather than the
  # group.
  #
  # Read off any row, because the windows carry the same two figures on all of them; `to_i` over the
  # nil of an empty read, where zero is the honest count. The same "read it off whichever row you
  # have" shape `SpecFileExamples` uses one drill-down over.
  def recorded_count = window_count("description_recorded_count")

  def timed_count = window_count("description_timed_count")

  # Whether this run recorded any rows under this description AT ALL — the question that decides
  # whether the panel has a list or an empty state. A row exists here if and only if the run wrote
  # one carrying this name, so this is `rows` being non-empty and needs no separate count.
  def recorded? = rows.any?

  # Rows this run recorded here and did not time. Not a defect and not a gap to paper over: an
  # example that never ran has no duration to report, so the nil is a faithful record — see
  # `Ingest::ObservationRecorder#attributes`. They are LISTED rather than excluded, at the end of the
  # list rather than the head of it; this is how many of them the GROUP holds.
  def untimed_count = recorded_count - timed_count

  # == What is actually on the page, as against what the group holds
  #
  # The three figures above are windows counted before the cap, which is what makes them true of the
  # DESCRIPTION. That is the whole point of them and it is also the trap `SpecFileExamples` documents
  # one drill-down over: on a truncated group they describe rows a reader cannot see, and a caption
  # that spends them as though they were the list says "the other 300 sit at the end of this list"
  # over a page holding twenty-five of them.
  #
  # These two are counted off the LOADED ROWS instead — the ones rendered — so a caption can say how
  # much of each population it is showing.
  def shown_timed_count = rows.count { |row| !row.duration_seconds.nil? }

  def shown_untimed_count = rows.size - shown_timed_count

  # Untimed examples this group holds that the cap left off the page ENTIRELY — not at the end of the
  # list, not anywhere in it. The figure that has to be said out loud, because the sentence a reader
  # would otherwise be given ("the other 300 reported none and sit at the END of the list") is the
  # one shape of this panel where it is false.
  def untimed_omitted_count = untimed_count - shown_untimed_count

  # The list's tail is untimed rows. Decides whether "the 25 slowest" is a description of this page
  # or a claim about it that is false: those rows are not the slowest of anything, they are the
  # lowest-`id` rows of a population nothing ranked, and they only reach the page at all because the
  # timed rows ran out before the cap did.
  def lists_untimed? = shown_untimed_count.positive?

  # Every example under this description reported a duration — the state worth SAYING rather than
  # leaving a reader to compare two numbers to reach.
  def complete? = recorded? && timed_count == recorded_count

  # Not one example under this description reported a duration. Distinct from `#recorded?` for the
  # reason every panel at this grain keeps the two apart: "this run recorded nothing here" and "this
  # run measured nothing here" are different facts, and only the first is an empty group. The list
  # still renders — the examples exist, they ran or failed to, and their outcomes and sites are worth
  # reading, which on THIS panel is most of what the reader came for — but nothing in it is ranked,
  # and a caption promising "slowest first" over it would be ranking nothing.
  def any_timed? = timed_count.positive?

  # There are examples under this description the list does not show. The state the caption has to
  # SAY rather than leave a reader to infer from a list whose length happens to equal a limit they
  # cannot see — the argument `RepeatedDescriptions#truncated?` makes one grain up, where the
  # population is descriptions and here is examples.
  def truncated? = recorded_count > rows.size

  # How much of the group the listed durations cover, always as a fraction and never as a bare count
  # — the spelling `RepeatedDescriptions::Row#coverage_label` uses for the row this drills out of, so
  # the same claim about the same group reads the same way on both.
  def coverage_label = "#{timed_count} of #{recorded_count}"

  private

  # `to_i` over `nil` twice: over the empty read that has no row to carry a window, and over the
  # attribute itself, since a count arriving as anything but an Integer must still leave the captions
  # doing arithmetic on integers.
  def window_count(attribute) = rows.first&.[](attribute).to_i
end
