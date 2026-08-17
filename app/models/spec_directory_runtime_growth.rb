# frozen_string_literal: true

# Which AREAS of the suite got SLOWER or FASTER between the latest run and the previous run ON THE
# SAME BRANCH — per directory: the summed example duration then, the summed example duration now,
# and the movement between them, ranked by how far each moved.
#
# == Why this is a sibling of `SpecDirectoryGrowth` and not a column added to it
#
# That panel answers "which areas changed SIZE" and this one answers "which areas changed TIME",
# and neither is derivable from the other. An area where somebody made an existing spec slow adds
# zero examples, so its `ABS(latest_count - previous_count)` is 0: it sorts last on that panel and
# falls off the cap. It is not a row there missing a column — it is not on that list at all.
#
# The independence runs both ways. Splitting one slow spec into four fast ones is `+3` examples and
# *less* time; adding a `sleep` to a shared `before` is `0` examples and minutes. A ranking by one
# quantity cannot also be a ranking by the other, which is why `SpecFileDurations` and
# `SlowestExamples` are two objects over one run's rows for exactly this reason — and why widening
# the count read would have silently re-ranked a shipped panel rather than added this one.
#
# The Overview panel's runtime delta is the other neighbour, and it stops one grain short: it is
# one number for the whole run — the run got 90 seconds slower — and it cannot say WHERE, because
# `test_runs.duration_seconds` has exactly one figure in it per run. The per-area grain only exists
# in `spec_observations`, and nothing had ever summed those durations across two runs.
#
# == It compares populations; it matches no tests
#
# `SpecObservation.directory_runtime_growth_between` carries the argument in full and it is the
# same premise `SpecDirectoryGrowth` stands on: this sums each area's rows in each run and
# subtracts two numbers. No `example_id` crosses the run boundary and no example is paired with
# another example, so nothing here asserts that a given test is the same test — the thing
# `example_id`'s positional instability forbids.
#
# == A move is not a slowdown, and this object cannot tell the difference
#
# `SpecDirectoryGrowth`'s disclosure carries over unchanged, in seconds instead of examples. A test
# that MOVES is the same test — `file_path` is only "last known path" (Project Goals) — so a
# directory rename, or a batch of specs moved one directory over, reads here as one area gaining
# time and another losing the same amount, with nothing having got slower and nothing faster.
# Nothing in the schema distinguishes that from a real regression and a real win, so the panel says
# so rather than implying an authorship it cannot see.
#
# == Why the comparability gate is the COUNT panel's three and not the runtime delta's four
#
# The gate is `SpecDirectoryGrowth`'s, verbatim: `TestRun#suite_size_measured?` on each side,
# `TestRun#assembled_like?` across them, and this grain's own third condition that both runs
# actually wrote rows here. Reused rather than re-spelled, for the reason `SuiteTrajectory`'s class
# comment gives — a third spelling is how two surfaces on one page eventually disagree about
# whether the same run measured a suite.
#
# What this does NOT take is the Overview runtime delta's fourth guard, equal `timed_shard_count`
# (`repositories/show.html.erb`) — and declining it is a decision rather than an oversight, so here
# is the reasoning, as the mirror image of `spec_directory_growth.rb`'s.
#
# That guard exists because a run's wall clock is a **MAX over its shards**: four timed shards
# taking 600s, against four shards whose two slowest were cancelled taking 180s, have identical
# `shard_count` and identical `suite_size_measured?`, and differencing them reports a 70% speedup
# produced entirely by telemetry loss. The denominator of a MAX is the shards that REPORTED, so
# that panel has to ask how many did.
#
# This read sums **per-example rows** — machine time, not wall clock — so it has no MAX to fold and
# no shard denominator to compare. A shard that vanished took its rows with it, and rows that were
# never written are not silently averaged into anything: they are missing from `recorded`, which
# every figure on this panel is stated against. Demanding a durations-shaped guard the measurement
# does not need would withhold comparisons that are sound — the same sentence
# `SpecDirectoryGrowth` writes about the same guard, arriving at the same answer from the other
# side. Where a shard genuinely went missing, `assembled_like?` is what catches it, exactly as it
# does for the counts.
#
# == The absences are the point, and there are two grains of them
#
# `SUM` skips NULLs silently and `duration_seconds` is nullable by design, so this object has to
# keep apart three things that all render as an empty cell: an area with no ROWS on a side, an area
# with rows none of which were TIMED on that side, and an area that genuinely took no time. The
# first two are not measurements and must never be spelled `0.00s` —
# `SpecObservation.humanized_duration` is the one seam that decides that, at every grain — and at
# the run level they are two more states in `#state`, because "the previous run recorded no
# per-example detail" and "the previous run reported no timings" are the same blank panel and two
# different things to go and fix.
#
# == One object, so the caption cannot drift from the table
#
# Unchanged from every sibling: a caption is a claim ABOUT the list, so "the 10 of 63 areas whose
# time moved most" is only true if both figures were counted off the rows the table lists. Every
# figure here comes back from one grouped aggregate — one round trip, constant in the size of the
# suite — and this object holds the rows and the sentences about them together.
class SpecDirectoryRuntimeGrowth
  # Builds the comparison, or the stated reason there isn't one.
  #
  # The comparability gate runs BEFORE the query and short-circuits it, exactly as
  # `SpecDirectoryGrowth.for` does and for the same reason: a page that cannot compare asks this
  # table nothing at all, so the panel costs zero queries in every one of the three states
  # decidable from the two runs alone. Both runs are already in memory on the caller
  # (`RepositoriesController#show`), and `assembled_like?` reads `shard_count` out of the memoized
  # `TestRun#shard_totals` that page has already taken for both rows — so the gate itself is free.
  #
  # The remaining states are decidable only from the rows, and cost the one query the comparison
  # costs anyway.
  def self.for(test_run, previous_test_run, limit: SpecObservation::RETIMED_DIRECTORIES_LIMIT)
    return new(state: :latest_unmeasured) unless test_run.suite_size_measured?
    return new(state: :previous_unmeasured) unless previous_test_run.suite_size_measured?
    return new(state: :assembled_differently) unless test_run.assembled_like?(previous_test_run)

    from_tuples(
      SpecObservation.directory_runtime_growth_between(test_run, previous_test_run, limit: limit)
    )
  end

  # The five window totals ride on every row and are identical on all of them, so they are read off
  # the first; `to_i` on the nil of an empty read, where zero areas and zero rows on both sides is
  # the honest count. An empty read is exactly the "neither run recorded rows" state — a group
  # exists here if and only if a row exists — so it needs no separate count to detect.
  #
  # The two grains of absence are asked in order, and the order is what makes each answer true: a
  # side that recorded no rows also timed none, so the RECORDED questions come first and the TIMED
  # ones only ever fire on a side that has rows and no timings. Collapsing them would tell a
  # reader whose client posts totals and no per-example detail to go and look for missing durations.
  #
  # Every state carries the totals, not only the comparable one. A panel saying "this run reported
  # no timings" is owed the figure that makes it actionable — it recorded 4,102 examples and timed
  # none of them — and the read has already paid for it; withholding it would leave the reader with
  # a sentence they cannot size.
  def self.from_tuples(tuples)
    _path, _prev_s, _latest_s, _prev_rec, _latest_rec, _prev_timed, _latest_timed,
      directory_count, previous_recorded, latest_recorded, previous_timed, latest_timed = tuples.first

    totals = { directory_count: directory_count.to_i,
               previous_recorded_count: previous_recorded.to_i, latest_recorded_count: latest_recorded.to_i,
               previous_timed_count: previous_timed.to_i, latest_timed_count: latest_timed.to_i }

    return new(state: :neither_recorded, **totals) if previous_recorded.to_i.zero? && latest_recorded.to_i.zero?
    return new(state: :previous_unrecorded, **totals) if previous_recorded.to_i.zero?
    return new(state: :latest_unrecorded, **totals) if latest_recorded.to_i.zero?
    return new(state: :neither_timed, **totals) if previous_timed.to_i.zero? && latest_timed.to_i.zero?
    return new(state: :previous_untimed, **totals) if previous_timed.to_i.zero?
    return new(state: :latest_untimed, **totals) if latest_timed.to_i.zero?

    rows = tuples.map do |path, prev_seconds, latest_seconds, prev_rec, latest_rec, prev_t, latest_t, *|
      Row.new(path: path, previous_seconds: prev_seconds, latest_seconds: latest_seconds,
              previous_recorded_count: prev_rec.to_i, latest_recorded_count: latest_rec.to_i,
              previous_timed_count: prev_t.to_i, latest_timed_count: latest_t.to_i)
    end

    new(state: :comparable, rows: rows, **totals)
  end
  private_class_method :from_tuples

  def initialize(state:, rows: [], directory_count: 0, previous_recorded_count: 0,
                 latest_recorded_count: 0, previous_timed_count: 0, latest_timed_count: 0)
    @state = state
    @rows = rows
    @directory_count = directory_count
    @previous_recorded_count = previous_recorded_count
    @latest_recorded_count = latest_recorded_count
    @previous_timed_count = previous_timed_count
    @latest_timed_count = latest_timed_count
  end

  # Which of the ten states this is — one comparable, nine not. A symbol rather than a boolean
  # because the nine absences are different facts about the two runs and a reader is owed the one
  # that applies: "the earlier run reported no tests", "the earlier run recorded no per-example
  # rows" and "the earlier run reported no timings" are one blank panel and three different things
  # to go and fix.
  attr_reader :state

  # The comparison, largest movement in seconds first. Never longer than the limit it was built
  # with, and empty in every non-comparable state.
  attr_reader :rows

  # How many areas the comparison COVERED in total — every directory either run recorded a row in,
  # counted before the `LIMIT` and therefore not `rows.size`. The list is capped, so its own length
  # answers "how many rows am I looking at" and nothing else; a caption built on it would read "the
  # areas whose time moved most" on a page showing ten of sixty-three.
  attr_reader :directory_count

  # How many per-example rows each run recorded in total, and how many of those carried a timing —
  # the denominators every figure on this panel is stated against, counted before the `LIMIT`.
  #
  # Both, and never only the timed count: "1,204 examples reported a timing" is 1,204 of something
  # unstated, and the whole reading this panel turns on is whether an area got faster or merely
  # went quiet. Deliberately NOT `TestRun#total_specs_count` — that column is re-derived by SUM
  # over shard reports and can legitimately differ from the rows the run actually wrote here.
  attr_reader :previous_recorded_count, :latest_recorded_count
  attr_reader :previous_timed_count, :latest_timed_count

  def comparable? = state == :comparable

  # There are areas the comparison covered that the list does not show.
  def truncated? = directory_count > rows.size

  # At least one listed area's summed duration actually moved. False for two runs whose every area
  # took the same time — a real and unremarkable answer ("nothing got slower"), worth saying in
  # words rather than showing as a table of `±0` under a heading promising areas that changed pace.
  #
  # Asked of the LISTED rows, which is sound in exactly one direction and that is the direction
  # this needs: the ranking is by absolute movement descending, so if any area moved at all the top
  # row is one that did. A false here is therefore a claim about every area the comparison covered.
  def any_movement? = rows.any?(&:moved?)

  # At least one LISTED area has both sides timed and did not move. The ranking is by absolute
  # movement descending and the list is capped, so unmoved areas can only appear in its tail — and
  # they appear exactly when fewer areas moved than the cap has room for. Not a defect (the reader
  # is seeing where the movement ran out) but it does mean a list headed "the areas whose time
  # moved most" can contain areas whose time did not move, so the caption has a clause for it.
  def any_unmoved? = rows.any? { |row| row.comparable? && !row.moved? }

  # At least one LISTED area has no movement to state because a side of it was never timed. Those
  # rows sort LAST (the ordering key is NULL and the read asks for `NULLS LAST`), so they appear
  # for the same reason unmoved rows do — the movement ran out before the cap did — and they need
  # their own clause, because "not reported" in a Change column is a different sentence from `±0`.
  def any_untimed? = rows.any? { |row| !row.comparable? }

  # At least one LISTED area is a TIMING GAP specifically: both runs ran it, and one of them
  # reported no duration for it. Narrower than `any_untimed?` on purpose, and the caption uses this
  # one — an area only one run HAS is also uncomparable, but its cell already says "New area" or
  # "Area removed", and a sentence about runs that "reported no timing" would be describing a
  # different row from the one the reader is looking at. Two absences, two cells, two sentences.
  def any_timing_gap? = rows.any?(&:timing_gap?)

  # There is a table worth rendering: some listed area either moved or has an absence to disclose.
  #
  # `any_movement?` alone is NOT that question, and the difference is the one this panel exists for.
  # An area that stopped reporting timings, an area only one run has — those rows moved by nothing
  # because there is nothing to subtract, and they are exactly the rows a reader must see rather
  # than have folded into "no area changed pace". That sentence is a claim that two runs took the
  # same time, and it is false of a suite half of which went unmeasured.
  #
  # So the empty state is the complement of THIS, and it means what it says: every listed area had
  # both sides timed and neither side moved.
  def anything_to_show? = any_movement? || any_untimed?

  # One directory's movement in seconds between two runs, both operands it was taken across, and
  # what each operand was summed over.
  Row = Struct.new(:path, :previous_seconds, :latest_seconds, :previous_recorded_count,
                   :latest_recorded_count, :previous_timed_count, :latest_timed_count,
                   keyword_init: true) do
    # This area has a movement at all: both sides summed a real number of seconds. False whenever
    # either side timed nothing here, which is SQL NULL out of the aggregate and stays nil all the
    # way to the cell — a subtraction against it would be arithmetic on a zero that was never a
    # measurement of this area.
    def comparable? = !previous_seconds.nil? && !latest_seconds.nil?

    # Signed, and the sign carries the whole meaning: an area that gained 47 seconds and one that
    # shed 47 are opposite facts. Nil where there is nothing to subtract.
    def change = comparable? ? latest_seconds - previous_seconds : nil

    def moved? = comparable? && !change.zero?

    # This area is in the new run and not in the old one — asked of the ROWS and never of the
    # seconds, because an area both runs ran and neither timed also has two nil sums and is a
    # completely different fact. The object holding this row has already established that both runs
    # recorded rows, so a zero here is this run genuinely having nothing in this area.
    def new_area? = previous_recorded_count.zero?

    def removed_area? = latest_recorded_count.zero?

    # Both runs RAN this area and one of them did not time it — the absence that is about the
    # reporting rather than about the area existing. Distinct from `new_area?`/`removed_area?`,
    # whose nil sums come from a side having no rows here at all, and which the Change cell names
    # in their own words.
    def timing_gap? = !comparable? && !new_area? && !removed_area?

    # Each operand, rendered — through the same seam one example's duration, one file's total and
    # one area's total are rendered through, so no two grains on this page can disagree about how a
    # duration is spelled, and a side that timed nothing says "not reported" rather than "0.00s".
    def previous_label = SpecObservation.humanized_duration(previous_seconds)

    def latest_label = SpecObservation.humanized_duration(latest_seconds)

    # How much of this area each side actually timed, always as a fraction and never as a bare
    # count — `SpecObservation.coverage_fraction`'s rule, doubled because there are two sides:
    # "12" in a column of "12 of 40" reads as twelve of something unstated, and a total summed over
    # a third of an area is exactly the reading this column exists to qualify. Doubled is also why
    # it is built here instead of spelled through that seam, which draws the boundary in its own
    # words: it renders ONE population, for the single-sided callers like
    # `SpecDirectoryDurations::Row#coverage_label`, and a two-sided comparison is a different
    # sentence rather than that one said twice.
    def coverage_label
      "#{previous_timed_count} of #{previous_recorded_count} → " \
        "#{latest_timed_count} of #{latest_recorded_count}"
    end

    # What moved, rendered.
    #
    # An area present on only one side says so instead of printing a delta, for the reason
    # `SpecDirectoryGrowth::Row#change_label` gives: `+40s` against an absent side is arithmetic on
    # a zero that was never a measurement of this area, and it reads identically to an existing
    # area that got forty seconds slower — the one distinction a reader scanning this column most
    # needs. An area present on both sides but timed on only one gets its own reading for the same
    # reason and a different cause: nothing regressed, the telemetry did.
    #
    # `±0` for an area whose time did not move, on the rule `ApplicationHelper#suite_size_change`
    # sets: "compared, and it did not move" is a real answer and `+0` claims a direction it does
    # not have. A true minus (U+2212) and not a hyphen-minus, for that helper's typographic reason
    # — this renders in a `tabular-nums` column under and over other signed figures, and a hyphen
    # is drawn narrower and lower than the `+` it has to align with.
    #
    # A movement too small for the two decimals `humanized_duration` prints comes back "+< 0.01s"
    # rather than "+0.00s", which is that method's own rule and the reason it is reused here: a
    # measurement wearing the spelling of a zero is the one reading it exists to refuse.
    def change_label
      return "New area" if new_area?
      return "Area removed" if removed_area?
      return "Not timed" unless comparable?
      return "±0" unless moved?

      "#{change.negative? ? "−" : "+"}#{SpecObservation.humanized_duration(change.abs)}"
    end

    # The same fact in words, for the `aria-label` on that cell.
    #
    # Both halves of the visible rendering fail when read aloud, exactly as they do one panel up:
    # the row announces as a path and several unattached numbers, and U+2212 — chosen above
    # precisely because it is not a hyphen — is announced inconsistently across screen readers,
    # from "minus" to nothing at all. So the direction and what it was measured against are spelled
    # out rather than left to the glyph.
    def change_reading
      return new_area_reading if new_area?
      return removed_area_reading if removed_area?
      return untimed_reading unless comparable?
      return "took the same time as it did in the previous run on this branch" unless moved?

      "#{SpecObservation.humanized_duration(change.abs)} " \
        "#{change.negative? ? "faster" : "slower"} than the previous run on this branch"
    end

    private

    # A new area normally announces its own total, which is the magnitude a reader wants. But an
    # area can be BOTH new and untimed, and "not reported of examples" is not a sentence — so the
    # two facts are said as two facts rather than run through one template.
    def new_area_reading
      return "an area the previous run did not record, and this run reported no timing for it" if latest_seconds.nil?

      "#{latest_label} of examples, an area the previous run did not record"
    end

    def removed_area_reading
      return "an area this run does not have, and the previous run reported no timing for it" if previous_seconds.nil?

      "#{previous_label} of examples in the previous run and none now"
    end

    # Which side went quiet, said as a fact about the REPORTING and never about the code. This is
    # the row whose visible cell reads "Not timed", and the one place a reader could otherwise
    # infer a speedup from an absence.
    def untimed_reading
      return "neither run reported a timing for this area" if previous_seconds.nil? && latest_seconds.nil?
      return "this run reported no timing for this area, so there is nothing to compare" if latest_seconds.nil?

      "the previous run on this branch reported no timing for this area, so there is nothing to compare"
    end
  end
end
