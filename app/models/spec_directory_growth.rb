# frozen_string_literal: true

# Which AREAS of the suite grew or shrank between the latest run and the previous run ON THE SAME
# BRANCH — per directory: the example count then, the example count now, and the movement between
# them, ranked by how far each moved.
#
# The Overview panel's suite-size delta answers "did the suite grow", one integer for the whole
# suite. It cannot say WHERE, and no level can: `SuiteTrajectory` plots `TestRun#total_specs_count`
# over thirty runs and that column has exactly one number in it per run. The per-area grain only
# exists in `spec_observations`, and nothing had ever grouped that table across two runs.
#
# == It compares populations; it matches no tests
#
# `SpecObservation.directory_growth_between` carries the full argument and it is the premise the
# whole object stands on: this counts rows per area in each run and subtracts two integers. No
# `example_id` crosses the run boundary and no example is paired with another example, so nothing
# here asserts that a given test is the same test — the thing `example_id`'s positional instability
# forbids, and the reason every sibling panel is scoped to one run.
#
# == A movement is not necessarily a growth, and this object cannot tell the difference
#
# A test that MOVES is the same test — `file_path` is only "last known path" (Project Goals) — so a
# directory rename, or a batch of specs moved one directory over, reads here as one area growing
# and another shrinking by the same amount with nothing added and nothing deleted. Nothing in the
# schema distinguishes that from a real gain and a real loss, so the panel says so rather than
# implying an authorship it cannot see. That disclosure is not decoration; it is the difference
# between a figure a reader can act on and one they will act on wrongly.
#
# == Why the comparability gate is here and not in the query
#
# A change is worth as much as the WEAKER of the two rows it is taken across, and this grain has
# THREE conditions rather than the Overview delta's two.
#
# The first two are the Overview delta's own, asked through the Overview delta's own predicates:
# `TestRun#suite_size_measured?` on each side, and `TestRun#assembled_like?` across them. They are
# reused rather than re-spelled because `SuiteTrajectory`'s class comment is explicit about what a
# third spelling costs — it is how two surfaces on one page eventually disagree about whether the
# same run measured a suite. This panel is the third caller and it spells nothing new.
#
# `assembled_like?` and NOT the runtime delta's additional `timed_shard_count` check, for the
# reason `repositories/show.html.erb` gives where those two guards sit side by side: equal shard
# count is the right question for a COUNT, whose denominator is the shards recorded so far, and
# `timed_shard_count` is the denominator of a MAX over the shards that reported. This panel
# measures no durations at all, so demanding a condition belonging to durations would withhold
# comparisons that are sound.
#
# The third condition is this grain's own, and neither predicate above covers it: **both runs must
# have WRITTEN example rows.** `total_specs_count` is written by `Ingest::RunRecorder` and the
# per-example rows by `Ingest::ObservationRecorder`, and a run can have the first without the
# second — one ingested before those rows existed, or sent by a client that posts no per-example
# detail. Such a run is fully "measured" by both predicates above and has zero rows here, so a
# comparison against it renders the entire suite as deleted, area by area, in a panel that has just
# certified both sides as comparable. The recorded totals come back on the same aggregate.
#
# == One object, so the caption cannot drift from the table
#
# `SpecFileDurations` and `SpecDirectoryDurations` state the rule and it is unchanged here: a
# caption is a claim ABOUT the list, so "the 10 of 63 areas that moved most" is only true if both
# figures were counted off the rows the table lists. Every figure on this panel comes back from one
# grouped aggregate — one round trip, constant in the size of the suite — and the object holds the
# rows and the sentences about them together.
#
# What differs from those two is the shape of the absences. There, a panel either had rows or said
# it had none. Here there are six distinct reasons a comparison cannot be made and they are
# different facts, so `#state` names WHICH one rather than collapsing them into a single "cannot
# compare" — the register `repositories/show.html.erb` sets for the Overview delta's own
# no-comparison states, where withholding a figure means saying why.
class SpecDirectoryGrowth
  # Builds the comparison, or the stated reason there isn't one.
  #
  # The comparability gate runs BEFORE the query and short-circuits it: a page that cannot compare
  # asks this table nothing at all, so the panel costs zero queries in every one of the three
  # states decidable from the two runs alone. Both runs are already in memory on the caller
  # (`RepositoriesController#show`), and `assembled_like?` reads `shard_count` out of the memoized
  # `TestRun#shard_totals` that page has already taken for both rows — so the gate itself is free.
  #
  # The remaining three states are decidable only from the rows, and cost the one query the
  # comparison costs anyway.
  def self.for(test_run, previous_test_run, limit: SpecObservation::MOVED_DIRECTORIES_LIMIT)
    return new(state: :latest_unmeasured) unless test_run.suite_size_measured?
    return new(state: :previous_unmeasured) unless previous_test_run.suite_size_measured?
    return new(state: :assembled_differently) unless test_run.assembled_like?(previous_test_run)

    from_tuples(SpecObservation.directory_growth_between(test_run, previous_test_run, limit: limit))
  end

  # The three window totals ride on every row and are identical on all of them, so they are read
  # off the first; `to_i` on the nil of an empty read, where zero areas and zero rows on both sides
  # is the honest count. An empty read is exactly the "neither run recorded rows" state — a group
  # exists here if and only if a row exists — so it needs no separate count to detect.
  def self.from_tuples(tuples)
    _path, _previous, _latest, directory_count, previous_recorded, latest_recorded = tuples.first
    return new(state: :neither_recorded) if previous_recorded.to_i.zero? && latest_recorded.to_i.zero?
    return new(state: :previous_unrecorded) if previous_recorded.to_i.zero?
    return new(state: :latest_unrecorded) if latest_recorded.to_i.zero?

    rows = tuples.map do |path, previous, latest, *|
      Row.new(path: path, previous_count: previous.to_i, latest_count: latest.to_i)
    end

    new(state: :comparable, rows: rows, directory_count: directory_count.to_i,
        previous_recorded_count: previous_recorded.to_i, latest_recorded_count: latest_recorded.to_i)
  end
  private_class_method :from_tuples

  def initialize(state:, rows: [], directory_count: 0, previous_recorded_count: 0, latest_recorded_count: 0)
    @state = state
    @rows = rows
    @directory_count = directory_count
    @previous_recorded_count = previous_recorded_count
    @latest_recorded_count = latest_recorded_count
  end

  # Which of the seven states this is — one comparable, six not. A symbol rather than a boolean
  # because the six absences are different facts about the two runs and a reader is owed the one
  # that applies: "the earlier run reported no tests" and "the earlier run recorded no per-example
  # rows" are the same blank panel and two different things to go and fix.
  attr_reader :state

  # The comparison, largest movement first. Never longer than the limit it was built with, and
  # empty in every non-comparable state.
  attr_reader :rows

  # How many areas the comparison COVERED in total — every directory either run recorded a row in,
  # counted before the `LIMIT` and therefore not `rows.size`. The list is capped, so its own length
  # answers "how many rows am I looking at" and nothing else; a caption built on it would read "the
  # areas that moved most" on a page showing ten of sixty-three, which is a truncated list wearing
  # the shape of a complete one.
  attr_reader :directory_count

  # How many per-example rows each run recorded in total — the denominators the comparability gate
  # turned on, kept so the caption can state what the panel was measured over. Deliberately NOT
  # `TestRun#total_specs_count`: that column is re-derived by SUM over shard reports and can
  # legitimately differ from the rows the run actually wrote here, and every figure on this panel
  # is counted off those rows.
  attr_reader :previous_recorded_count, :latest_recorded_count

  def comparable? = state == :comparable

  # There are areas the comparison covered that the list does not show.
  def truncated? = directory_count > rows.size

  # At least one listed area's example count actually moved. False for two runs that recorded the
  # same number of examples in every area — a real and unremarkable answer ("nothing moved"), and
  # one worth saying in words rather than showing as a table of `±0` under a heading promising
  # areas that grew or shrank.
  #
  # Asked of the LISTED rows, which is sound in exactly one direction and that is the direction
  # this needs: the ranking is by absolute movement descending, so if any area moved at all the
  # top row is one that did. A false here is therefore a claim about every area the comparison
  # covered, not only the ten on the page.
  def any_movement? = rows.any?(&:moved?)

  # At least one LISTED area did not move. The ranking is by absolute movement descending and the
  # list is capped, so unmoved areas can only ever appear in its tail — and they appear exactly
  # when fewer areas moved than the cap has room for. That is not a defect (the reader is seeing
  # where the movement ran out) but it does mean a list headed "the areas that moved most" can
  # contain areas that did not move at all, so the caption has a clause for it and this is what
  # decides whether that clause is true. Asked of the rows rather than derived from a count,
  # because it is a claim about what is on the page.
  def any_unmoved? = rows.any? { |row| !row.moved? }

  # One directory's movement between two runs, and both operands it was taken across.
  Row = Struct.new(:path, :previous_count, :latest_count, keyword_init: true) do
    # Signed, and the sign carries the whole meaning: an area that gained 47 examples and one that
    # lost 47 are opposite facts.
    def change = latest_count - previous_count

    def moved? = !change.zero?

    # This area is in the new run and not in the old one. A group exists here only if one of the
    # two runs wrote a row for it, and the object holding this row has already established that
    # BOTH runs recorded rows — so a zero on one side is that run genuinely having nothing in this
    # area, not a run that recorded nothing anywhere.
    def new_area? = previous_count.zero?

    def removed_area? = latest_count.zero?

    # What moved, rendered.
    #
    # An area present on only one side says so instead of printing a delta. `+40` against an
    # absent side is arithmetic on a zero that was never a measurement of this area, and it reads
    # identically to an existing area that gained forty tests — which is the one distinction a
    # reader scanning this column most needs. Both operands sit in the two cells beside this one,
    # so naming the state here loses no magnitude.
    #
    # `±0` for an area that did not move, on the rule `ApplicationHelper#suite_size_change` sets
    # for the figure this panel sits under: "compared, and it did not move" is a real answer and
    # `+0` claims a direction it does not have.
    #
    # A true minus (U+2212) and not a hyphen-minus, for that helper's typographic reason — this
    # renders in a `tabular-nums` column directly under and over other signed numbers, and a hyphen
    # is drawn narrower and lower than the `+` it has to align with.
    #
    # Rendered here rather than through `suite_size_change` itself: that helper is named for the
    # one figure it renders and its own comment says why a general `signed_count` would be wrong —
    # the readings it hard-codes are the Overview delta's. This column has two states that figure
    # has no spelling for at all.
    def change_label
      return "New area" if new_area?
      return "Area removed" if removed_area?
      return "±0" unless moved?

      "#{change.negative? ? "−" : "+"}#{ActiveSupport::NumberHelper.number_to_delimited(change.abs)}"
    end

    # The same fact in words, for the `aria-label` on that cell.
    #
    # Both halves of the visible rendering fail when read aloud, exactly as they do for the
    # Overview delta one panel up: the row announces as a path and three unattached numbers, and
    # U+2212 — chosen above precisely because it is not a hyphen — is announced inconsistently
    # across screen readers, from "minus" to nothing at all. So the direction and what it was
    # measured against are spelled out rather than left to the glyph.
    def change_reading
      return "#{example_phrase(latest_count)}, an area the previous run did not record" if new_area?
      return "#{example_phrase(previous_count)} in the previous run and none now" if removed_area?
      return "unchanged since the previous run on this branch" unless moved?

      "#{example_phrase(change.abs)} #{change.negative? ? "fewer" : "more"} " \
        "than the previous run on this branch"
    end

    # An operand, rendered. Delimited here rather than in the template so both counts and the
    # change between them are spelled one way by one object.
    def previous_count_label = ActiveSupport::NumberHelper.number_to_delimited(previous_count)

    def latest_count_label = ActiveSupport::NumberHelper.number_to_delimited(latest_count)

    private

    def example_phrase(count)
      "#{ActiveSupport::NumberHelper.number_to_delimited(count)} #{"example".pluralize(count)}"
    end
  end
end
