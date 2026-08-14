# frozen_string_literal: true

# Which FILES of ONE area grew or shrank between the latest run and the previous run ON THE SAME
# BRANCH — per spec file: the example count then, the example count now, and the movement between
# them, ranked by how far each moved.
#
# The rung below `SpecDirectoryGrowth`, and the one that was missing. That panel names the ten areas
# whose example count moved most and then dead-ends: its directory cell was inert text, so the only
# question a row like `spec/models 412 → 459 (+47)` provokes — WHICH FILES DID THAT — could not be
# asked from the page or from anywhere else. Nothing in the application read growth at the file
# grain at all.
#
# "Heaviest spec files" could not stand in, for the reason `SpecDirectoryDurations` gives about its
# own rollup one grain up: that list is a run-wide top ten ranked by DURATION, so an area that
# gained forty-seven fast examples has not one of its rows in it. The panel that can see the
# movement cannot see the files, and the panel that can see files cannot see the movement.
#
# == It counts populations; it matches no tests
#
# The premise the parent object stands on, restated here because this object is the one a reader
# will be most tempted to read as a correspondence: it counts rows per FILE in each run and
# subtracts two integers. No `example_id` crosses the run boundary and no example is paired with
# another example — an edit that joins these runs on `example_id` in order to say "this test moved"
# has left what this panel is allowed to say, whatever the numbers come out as. `example_id` is
# positional and not stable across refactors, which is why every sibling panel is scoped to one run.
#
# == What the finer grain buys, given that
#
# The parent panel's caption discloses a doubt and then leaves the reader holding it: a test that
# was MOVED is the same test, so a renamed or relocated directory reads there as one area growing
# and another shrinking by the same amount, with nothing added and nothing deleted. Nothing in the
# schema distinguishes that from a real gain and a real loss.
#
# This object does not resolve that doubt either — it cannot, and it asserts nothing new. What it
# does is put the operands where a HUMAN can resolve it: `spec/models/user_spec.rb 0 → 47` beside
# `spec/legacy/user_spec.rb 47 → 0` reads as a relocation at a glance, and
# `spec/models/billing_spec.rb 3 → 50` does not. The system still refuses to pair examples across
# runs; showing the file grain lets the reader do the pairing the system is not allowed to assert.
#
# == The comparability gate is the PARENT'S verdict, not a second spelling of it
#
# The five states in which there is no comparison to draw — `latest_unmeasured`,
# `previous_unmeasured`, `assembled_differently`, `previous_unrecorded`, `latest_unrecorded` — are
# `SpecDirectoryGrowth`'s, and they are INHERITED here rather than re-derived. `.for` takes the
# parent panel's own object and refuses to build anything the moment that panel is not comparable.
#
# That is stricter than reproducing the gate and it is stricter on purpose. Two reasons, and the
# second is the load-bearing one:
#
# 1. `SuiteTrajectory`'s class comment prices a THIRD spelling of the Overview delta's predicates,
#    and this would be a fourth: `TestRun#suite_size_measured?` and `#assembled_like?` are already
#    asked once by the panel above, on the same two runs, on the same page. Asking them again could
#    only ever produce the same answer or a bug.
#
# 2. The last two states CANNOT be re-derived here without changing what they mean. They are facts
#    about a RUN — that it wrote no per-example rows at all — and everything this object reads is
#    narrowed to one area. An area only the latest run recorded has zero previous-side rows, which
#    is `previous_unrecorded` spelled identically and meaning something else entirely: "the earlier
#    run recorded nothing anywhere" versus "this area is new". A drill-in that made that mistake
#    would announce a run as having reported no detail directly beneath a panel that is at that
#    moment listing that run's areas.
#
# The consequence is the rule the surface obeys: this drill-in is ABSENT whenever the panel it
# drills out of cannot compare. It is not a second opinion about two runs — it is a closer look at
# an answer the panel above has already given, and it must never assert a comparison its parent
# refuses.
#
# Not the runtime panel's additional `timed_shard_count` check, for the reason
# `SpecDirectoryGrowth` states: that guard is the denominator of a MAX over the shards that
# reported timings, and this measures no durations at all.
#
# == Zero queries when there is nothing to compare
#
# The gate is a read of an object already in memory, so it runs BEFORE the query in all five states
# and the drill-in costs the page nothing on a page that cannot compare — even with
# `?spec_directory=` set. The parent's own gate has already paid for itself; this adds no round trip
# to it.
#
# == One object, so the caption cannot drift from the table
#
# The rule every panel at every grain on this page keeps, unchanged: a caption is a claim ABOUT the
# list, so "the 30 of 41 files either run recorded in this area" is only true if both figures were
# counted off the rows the table lists. Every figure here comes back from the one grouped aggregate
# that returned the rows, as windows counted before the `LIMIT` — see
# `SpecObservation.file_growth_between`.
#
# == An area neither run recorded is not an error
#
# `?spec_directory=` is a URL a reader types, edits and bookmarks, and two runs that touched nothing
# in the area they ask for is an ordinary answer rather than a malformed request: a stale bookmark,
# a directory deleted since, a typo. That is `#recorded?` being false and the surface says so — the
# same shape `SpecDirectoryFiles` answers for the durations drill-down on the same ask.
class SpecDirectoryFileGrowth
  # Builds the comparison for one area, or nothing at all.
  #
  # `growth` is the parent panel's own `SpecDirectoryGrowth`, already built by the controller for
  # this same pair of runs. It is passed rather than rebuilt so the two panels cannot disagree about
  # whether these runs are comparable, and so this costs no second gate — see the class comment for
  # why the last two of its five states are not re-derivable at this grain in any case.
  def self.for(test_run, previous_test_run, path, growth:,
               limit: SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
    return new(path: path, state: growth.state) unless growth.comparable?

    from_tuples(path, SpecObservation.file_growth_between(test_run, previous_test_run, path,
                                                          limit: limit))
  end

  # The three window totals ride on every row and are identical on all of them, so they are read off
  # the first; `to_i` over the nil of an empty read, where zero files and zero rows on both sides is
  # the honest count. An empty read is exactly the "neither run recorded anything in this area"
  # state — a group exists here if and only if a row exists — so it needs no separate count to
  # detect, and it is `#recorded?` rather than a sixth state: the five states are about the RUNS and
  # this is about the AREA.
  def self.from_tuples(path, tuples)
    rows = tuples.map do |file_path, previous, latest, *|
      Row.new(path: file_path, previous_count: previous.to_i, latest_count: latest.to_i)
    end

    _path, _previous, _latest, file_count, previous_recorded, latest_recorded = tuples.first

    new(path: path, state: :comparable, rows: rows, file_count: file_count.to_i,
        previous_recorded_count: previous_recorded.to_i, latest_recorded_count: latest_recorded.to_i)
  end
  private_class_method :from_tuples

  def initialize(path:, state:, rows: [], file_count: 0, previous_recorded_count: 0,
                 latest_recorded_count: 0)
    @path = path
    @state = state
    @rows = rows
    @file_count = file_count
    @previous_recorded_count = previous_recorded_count
    @latest_recorded_count = latest_recorded_count
  end

  # The area that was asked for, as it was asked for. Held even when nothing came back, because the
  # empty state has to name it — "no spec files" without a subject is a sentence about nothing.
  attr_reader :path

  # The parent panel's verdict on the two runs, carried verbatim. `:comparable` or one of its five
  # refusals — never a state of this object's own devising, which is the whole point of it being
  # inherited.
  attr_reader :state

  # The comparison, largest movement first. Never longer than the limit it was built with, and empty
  # in every non-comparable state.
  attr_reader :rows

  # How many spec files the comparison COVERED in this area — every file either run recorded a row
  # for, counted before the `LIMIT` and therefore not `rows.size`. The list is capped, so its own
  # length answers "how many rows am I looking at" and nothing else; a caption built on it would
  # read "the files this area holds" on a page showing thirty of forty-one.
  attr_reader :file_count

  # How many per-example rows each run recorded IN THIS AREA — the denominators the caption states
  # what the panel was measured over. Deliberately not the parent's identically-named figures, which
  # are whole-run totals: every figure on this panel is counted off this area's rows, and a caption
  # mixing the two would divide an area's population by the suite's.
  attr_reader :previous_recorded_count, :latest_recorded_count

  def comparable? = state == :comparable

  # Either run recorded at least one example in this area. False for an area that is a typo, a stale
  # bookmark, or a directory both runs are innocent of — distinct from every one of the five
  # non-comparable states, which are about the RUNS and would be wrong to spell here.
  def recorded? = rows.any?

  # There are files the comparison covered that the list does not show.
  def truncated? = file_count > rows.size

  # At least one listed file's example count actually moved. False for an area whose every file
  # holds the same number of examples in both runs — a real and unremarkable answer, and the one a
  # reader who suspects a rename most wants confirmed, so it is worth saying in words rather than
  # showing as a table of `±0`.
  #
  # Asked of the LISTED rows, which is sound in exactly one direction and that is the direction this
  # needs: the ranking is by absolute movement descending, so if any file moved at all the top row
  # is one that did. A false here is therefore a claim about every file the comparison covered, not
  # only the thirty on the page. The argument `SpecDirectoryGrowth#any_movement?` makes one grain
  # up, unchanged by the grain.
  def any_movement? = rows.any?(&:moved?)

  # At least one LISTED file did not move. Unmoved files can only ever appear in the tail of a
  # ranking by absolute movement, and they appear exactly when fewer files moved than the cap has
  # room for — so a list headed "the files that moved most" can contain files that did not move at
  # all. Not a defect (the reader is seeing where the movement ran out) but the caption has a clause
  # for it, and this is what decides whether that clause is true.
  def any_unmoved? = rows.any? { |row| !row.moved? }

  # One spec file's movement between two runs, and both operands it was taken across.
  #
  # Deliberately NOT `SpecDirectoryGrowth::Row` reused or subclassed, though the arithmetic is
  # identical. Every string it renders names the grain — "New area" against "New file", "an area the
  # previous run did not record" against a file — and those readings are the whole product of the
  # struct: a shared Row would have to take its own nouns as arguments, which is a parameterised
  # sentence template standing where two plain sentences were, and the next grain to want a third
  # noun makes it three. The two structs are the same shape and not the same claim, which is the
  # disposition this codebase takes on its other near-identical row mappers.
  Row = Struct.new(:path, :previous_count, :latest_count, keyword_init: true) do
    # Signed, and the sign carries the whole meaning: a file that gained 47 examples and one that
    # lost 47 are opposite facts — and side by side in one area they are the two halves of the
    # rename this panel exists to make visible.
    def change = latest_count - previous_count

    def moved? = !change.zero?

    # This file is in the new run and not in the old one. A group exists here only if one of the two
    # runs wrote a row for it, and the object holding this row has already established — through the
    # parent panel's gate — that BOTH runs recorded rows. So a zero on one side is that run
    # genuinely having nothing in this file, not a run that recorded nothing anywhere.
    def new_file? = previous_count.zero?

    def removed_file? = latest_count.zero?

    # What moved, rendered.
    #
    # A file present on only one side says so instead of printing a delta, for the reason the area
    # grain gives and which is sharper here: `+47` against an absent side is arithmetic on a zero
    # that was never a measurement of this file, and it reads identically to an existing file that
    # gained forty-seven examples. At THIS grain that distinction is the panel's entire subject — a
    # file at "New file" beside one at "File removed" is the shape of a rename, and two files at
    # `+47` and `−47` is not. Both operands sit in the two cells beside this one, so naming the
    # state loses no magnitude.
    #
    # `±0` for a file that did not move, on the rule `ApplicationHelper#suite_size_change` sets for
    # the figure the panel above sits under: "compared, and it did not move" is a real answer and
    # `+0` claims a direction it does not have.
    #
    # A true minus (U+2212) and not a hyphen-minus, for that helper's typographic reason — this
    # renders in a `tabular-nums` column directly under and over other signed numbers, and a hyphen
    # is drawn narrower and lower than the `+` it has to align with.
    def change_label
      return "New file" if new_file?
      return "File removed" if removed_file?
      return "±0" unless moved?

      "#{change.negative? ? "−" : "+"}#{ActiveSupport::NumberHelper.number_to_delimited(change.abs)}"
    end

    # The same fact in words, for the `aria-label` on that cell.
    #
    # Both halves of the visible rendering fail when read aloud, exactly as they do one panel up:
    # the row announces as a path and three unattached numbers, and U+2212 — chosen above precisely
    # because it is not a hyphen — is announced inconsistently across screen readers, from "minus"
    # to nothing at all. So the direction and what it was measured against are spelled out rather
    # than left to the glyph.
    def change_reading
      return "#{example_phrase(latest_count)}, a file the previous run did not record" if new_file?
      return "#{example_phrase(previous_count)} in the previous run and none now" if removed_file?
      return "unchanged since the previous run on this branch" unless moved?

      "#{example_phrase(change.abs)} #{change.negative? ? "fewer" : "more"} " \
        "than the previous run on this branch"
    end

    # An operand, rendered. Delimited here rather than in the template so both counts and the change
    # between them are spelled one way by one object.
    def previous_count_label = ActiveSupport::NumberHelper.number_to_delimited(previous_count)

    def latest_count_label = ActiveSupport::NumberHelper.number_to_delimited(latest_count)

    private

    def example_phrase(count)
      "#{ActiveSupport::NumberHelper.number_to_delimited(count)} #{"example".pluralize(count)}"
    end
  end
end
