# frozen_string_literal: true

# Which AREAS of the suite grew or shrank ACROSS THE BRANCH WINDOW — the same last-thirty-runs
# window the "Suite growth" chart is loaded from — per directory: the example count at the far end
# of that window, the example count now, and the movement between them, ranked by how far each
# moved.
#
# The window, and not the chart's LINE: `SuiteTrajectory` withholds runs it may not plot, and this
# object walks the loaded rows under the comparability rule below. Same thirty rows in, two
# different subsets used, each stated by the surface that used it.
#
# Project Goals asks where the suite is growing *and how fast*: "growth over time, where the suite
# is growing, in which areas". The page had both halves and never their intersection. `SuiteTrajectory`
# has the window but no area grain at all — it plots `TestRun#total_specs_count`, one number per run
# — and `SpecDirectoryGrowth` has the area grain over exactly one push. An area that gains four
# examples in each of thirty runs never appears on that panel: `+4` is nobody's biggest mover, so it
# sorts below the cap every single time, and a hundred and twenty examples arrive unremarked.
#
# == Why this is a panel BESIDE `SpecDirectoryGrowth` and not a widening of it
#
# The two rank different populations and neither is derivable from the other, the same way
# `SpecDirectoryRuntimeGrowth` is a sibling of that panel rather than a column added to it. "What
# did this push do" and "what did this branch do" are different questions with different answers,
# and an area can head one list while being absent from the other — the steady-creep area above
# heads this one and is not on that one, and an area that gained 300 examples in the last push and
# was empty for the twenty-nine runs before it heads that one and, if those examples were then
# deleted again, does not appear here at all. Widening the shipped read would have silently re-ranked
# a shipped panel rather than adding this one.
#
# == It compares two ENDPOINTS. It is not a series, and it says so
#
# This is the load-bearing limitation, and it is bigger here than on any sibling because the window
# in the caption is thirty runs long. An area that added three hundred examples in run 12 and
# deleted them again in run 25 reads exactly `±0` here, and an area that lost everything and had it
# restored reads the same. Two endpoints are two measurements, not a trajectory, so the panel states
# that in words rather than letting a thirty-run caption imply a shape it never looked at.
#
# The per-area series that WOULD answer it — `GROUP BY directory, test_run_id` over all thirty run
# ids — is deliberately not this slice. It would be the first read in this application to scan a
# whole window unnarrowed (thirty runs × a twenty-thousand-example suite is ~600k rows per page
# load), where every shipped window read narrows first: `.unstable_identity_candidates_in` to
# `outcome: "failed"`, `.unstable_outcome_composition_in` to at most `UNSTABLE_CANDIDATE_LIMIT`
# identities. Two run ids is
# the certified shape, and that is what this reads.
#
# == It compares populations; it matches no tests
#
# Unchanged from `SpecDirectoryGrowth`, and the premise this object stands on exactly as it stands
# on that one: `SpecObservation.directory_growth_between` counts rows per area in each of two runs
# and subtracts two integers. No `example_id` crosses the run boundary and no example is paired with
# another example, so nothing here asserts that a given test is the same test — the thing
# `example_id`'s positional instability forbids. `UnstableTests` is the one reader on this page that
# does match a test to itself, and it carries its matching rule in its own caption.
#
# == A movement is still not necessarily a growth — and that disclosure is STRONGER over a window
#
# A test that MOVES is the same test: `file_path` is only "last known path" (Project Goals), so a
# directory rename reads here as one area growing and another shrinking by the same amount with
# nothing authored. Over one push a reader can often remember the rename. Over thirty runs and
# possibly weeks of history they cannot, and the panel is the only thing that can tell them the
# reading is available — so it says so in the same words the panel one rung up says them in.
#
# == The baseline is WALKED, and the panel names the run it landed on
#
# The anchor is the newest run of the window — the run the rest of the page is drawn on. The
# baseline is the OLDEST run of the window that can be compared against it, found by walking from
# the far end, so the comparison spans as much of the window as is sound rather than stopping at the
# first incomparable row.
#
# Which means the window a reader is shown can be SHORTER than the window in the caption, and that
# is a fact about the measurement rather than an implementation detail: a baseline chosen by walking
# past four unmeasured runs has quietly given the reader a twenty-six-run comparison under a
# thirty-run heading. So the object carries which run it landed on, how many runs back that is, and
# how many it stepped over and why — and the panel states all of it.
#
# The predicates are `SpecDirectoryGrowth`'s, reused and never re-spelled, for the reason
# `SuiteTrajectory`'s class comment gives: a third spelling of "did this run measure a suite" is how
# two surfaces on one page eventually disagree about the same run.
#
# * `TestRun#suite_size_measured?` on each side.
# * `TestRun#assembled_like?` across them — and NOT the runtime delta's additional
#   `timed_shard_count` check, for the reason `spec_directory_growth.rb` gives at length: this panel
#   measures no durations, and demanding a durations-shaped condition would withhold comparisons
#   that are sound.
# * Both runs must have WRITTEN example rows. Decidable only from the rows, so it is not part of the
#   walk — it rides back on the same aggregate exactly as it does on the panel one rung up, and a
#   run with a `total_specs_count` and no `spec_observations` rows compared against renders the
#   whole suite as deleted, area by area.
#
# The first two are decided ENTIRELY IN MEMORY and therefore cost nothing: the window is already
# loaded on `RepositoriesController#show` (it is the chart's own rows, handed in), and
# `assembled_like?` reads `shard_count` out of the count `Repository#suite_size_trajectory` primed
# onto every point of it. So a window with nothing to compare asks `spec_observations` nothing at
# all, and a window with something to compare asks it exactly once.
#
# == One object, so the caption cannot drift from the table
#
# The rule every sibling states, and it binds harder here because this caption makes more claims: a
# caption is a claim ABOUT the list, so "the 10 of 63 areas that moved most, measured against a run
# 26 back" is only true if every one of those figures was counted off the rows the table lists. All
# of them come back from one grouped aggregate or from the two runs the object chose, and the object
# holds the rows and the sentences about them together.
class SpecDirectoryWindowGrowth
  # Builds the comparison, or the stated reason there isn't one.
  #
  # @param runs [RunWindow, Array<TestRun>] the window, ALREADY LOADED, handed in as a {RunWindow}
  #   so its ORIENTATION travels with the rows instead of being re-asserted here in prose — the
  #   same rows the "Suite growth" chart and the "Tests whose outcome changed" panel were loaded
  #   for, handed in rather than re-queried. This object asks the window for
  #   {RunWindow#oldest_first}, because the anchor below is read off the NEWEST end as `runs.last`
  #   and the baseline walk starts at index 0 — the two ends are load-bearing, and a window read
  #   the wrong way round sign-flips every `change` without raising. The web surface builds
  #   `RunWindow.oldest_first`, the API asks `history_runs.oldest_first` off its newest-first
  #   window, and both name the order at their own load rather than here. A bare array is still
  #   accepted and read as oldest first — the contract this parameter used to carry in prose alone.
  #   Every panel that fetched "the last thirty runs on this branch" for itself would be its own
  #   window, with no structural reason to keep agreeing, on a page where each of them captions
  #   the others' branch.
  # @param branch [String, nil] the branch every figure is drawn on, for the caption.
  def self.for(runs, branch: nil, limit: SpecObservation::MOVED_DIRECTORIES_LIMIT)
    runs = RunWindow.wrap(runs)
    window_runs = runs.oldest_first
    anchor = window_runs.last
    context = { branch: branch, window_run_count: runs.size, anchor_run: anchor }

    return new(state: :anchor_unmeasured, **context) unless anchor&.suite_size_measured?
    return new(state: :no_earlier_run, **context) if runs.size < 2

    compare(window_runs, anchor, context, limit)
  end

  # The walk, and what it found. Separate from `.for` so the two questions asked of the anchor alone
  # stay legible above it, and private because the baseline rule is this object's own — a caller
  # that picked its own baseline would be a second spelling of the comparability predicates, which
  # is the thing this class comment exists to refuse.
  def self.compare(runs, anchor, context, limit)
    unmeasured = 0
    mismatched = 0
    index = nil

    # From the OLDEST end, so the comparison spans as much of the window as is sound. Each step is
    # two in-memory predicates over a row already loaded; nothing here touches the database.
    runs[0..-2].each_with_index do |run, position|
      next unmeasured += 1 unless run.suite_size_measured?
      next mismatched += 1 unless anchor.assembled_like?(run)

      index = position
      break
    end

    context = context.merge(skipped_unmeasured_count: unmeasured,
                            skipped_assembled_differently_count: mismatched)

    # No baseline, and WHICH condition ran the window out is the whole answer: a window whose
    # earlier runs all reported zero tests and one whose earlier runs were all sharded differently
    # are the same blank panel and two different things to go and fix. Composition takes precedence
    # because it is the stronger statement — reaching it means the walk DID find runs that measured
    # a suite, so "no earlier run measured anything" would be false of this window.
    if index.nil?
      return new(state: mismatched.positive? ? :no_comparable_composition : :no_measured_baseline,
                 **context)
    end

    from_tuples(SpecObservation.directory_growth_between(anchor, runs[index], limit: limit),
                **context, baseline_run: runs[index], runs_back: runs.size - 1 - index)
  end
  private_class_method :compare

  # The three window totals ride on every row of the aggregate and are identical on all of them, so
  # they are read off the first; `to_i` on the nil of an empty read, where zero areas and zero rows
  # on both sides is the honest count. An empty read is exactly the "neither run recorded rows"
  # state — a group exists here if and only if a row exists — so it needs no separate count.
  #
  # Every state carries the totals and the chosen baseline, not only the comparable one, on
  # `SpecDirectoryRuntimeGrowth`'s rule: a panel saying "the run at the far end of this window
  # recorded no per-example detail" is owed the figures that make it actionable — WHICH run, how far
  # back, and how many rows this run recorded against its none — and the read has already paid for
  # them.
  def self.from_tuples(tuples, **context)
    _path, _baseline, _anchor, directory_count, baseline_recorded, anchor_recorded = tuples.first

    totals = { directory_count: directory_count.to_i,
               baseline_recorded_count: baseline_recorded.to_i,
               anchor_recorded_count: anchor_recorded.to_i }

    return new(state: :neither_recorded, **context, **totals) if baseline_recorded.to_i.zero? &&
                                                                 anchor_recorded.to_i.zero?
    return new(state: :baseline_unrecorded, **context, **totals) if baseline_recorded.to_i.zero?
    return new(state: :anchor_unrecorded, **context, **totals) if anchor_recorded.to_i.zero?

    rows = tuples.map do |path, baseline, anchor, *|
      Row.new(path: path, previous_count: baseline.to_i, latest_count: anchor.to_i)
    end

    new(state: :comparable, rows: rows, **context, **totals)
  end
  private_class_method :from_tuples

  def initialize(state:, branch: nil, window_run_count: 0, anchor_run: nil, baseline_run: nil,
                 runs_back: 0, skipped_unmeasured_count: 0, skipped_assembled_differently_count: 0,
                 rows: [], directory_count: 0, baseline_recorded_count: 0, anchor_recorded_count: 0)
    @state = state
    @branch = branch
    @window_run_count = window_run_count
    @anchor_run = anchor_run
    @baseline_run = baseline_run
    @runs_back = runs_back
    @skipped_unmeasured_count = skipped_unmeasured_count
    @skipped_assembled_differently_count = skipped_assembled_differently_count
    @rows = rows
    @directory_count = directory_count
    @baseline_recorded_count = baseline_recorded_count
    @anchor_recorded_count = anchor_recorded_count
  end

  # Which of the eight states this is — one comparable, seven not. A symbol rather than a boolean
  # because the seven absences are different facts about the window and a reader is owed the one
  # that applies: "every earlier run on this branch reported no tests", "they were all assembled
  # differently from this one" and "the run at the far end recorded no per-example rows" are one
  # blank panel and three different things to go and fix.
  attr_reader :state

  # The branch every figure here was drawn on — the trajectory's branch, because a comparison taken
  # across branches is a comparison of different code.
  attr_reader :branch

  # How many runs the window HOLDS. Not how many the comparison spans: see `#covered_run_count`.
  attr_reader :window_run_count

  # The two runs the comparison was actually taken across. The anchor is the newest run of the
  # window; the baseline is the oldest one that could be compared against it, and is nil in the
  # states where the walk found none.
  attr_reader :anchor_run, :baseline_run

  # How many runs back in the window the baseline sits — 29 for a full thirty-run comparison, and
  # less whenever the walk stepped over something. Stated rather than assumed, because it is the
  # difference between the window a reader was promised and the one they were shown.
  attr_reader :runs_back

  # How many runs OLDER than the baseline the walk stepped over, split by which condition rejected
  # them. Split rather than summed because they are two different repairs — a client that stopped
  # reporting totals, and a branch whose sharding changed — and because a bare "4 runs were skipped"
  # is a fact a reader cannot act on.
  attr_reader :skipped_unmeasured_count, :skipped_assembled_differently_count

  # The comparison, largest movement first. Never longer than the limit it was built with, and empty
  # in every non-comparable state.
  attr_reader :rows

  # How many areas the comparison COVERED in total — every directory either run recorded a row in,
  # counted before the `LIMIT` and therefore not `rows.size`. The list is capped, so its own length
  # answers "how many rows am I looking at" and nothing else; a caption built on it would read "the
  # areas that grew most" on a page showing ten of sixty-three.
  attr_reader :directory_count

  # How many per-example rows each end of the comparison recorded in total — the denominators the
  # recorded-rows condition turned on, kept so the caption can state what the panel was measured
  # over. Deliberately NOT `TestRun#total_specs_count`: that column is re-derived by SUM over shard
  # reports and can legitimately differ from the rows the run actually wrote here, and every figure
  # on this panel is counted off those rows.
  attr_reader :baseline_recorded_count, :anchor_recorded_count

  def comparable? = state == :comparable

  # How many runs of the window the comparison actually SPANS, endpoints included. Equal to
  # `window_run_count` only where the walk stepped over nothing.
  def covered_run_count = runs_back + 1

  # The walk stepped over at least one run, so the comparison spans less of the window than the
  # window holds — the caption's cue to say so rather than let a thirty-run heading stand over a
  # twenty-six-run comparison.
  def shortened? = skipped_count.positive?

  def skipped_count = skipped_unmeasured_count + skipped_assembled_differently_count

  # There are areas the comparison covered that the list does not show.
  def truncated? = directory_count > rows.size

  # At least one listed area's example count actually moved across the window. False for two
  # endpoints that recorded the same number of examples in every area — a real answer, and one worth
  # saying in words rather than showing as a table of `±0` under a heading promising areas that grew.
  #
  # Asked of the LISTED rows, which is sound in exactly one direction and that is the direction this
  # needs: the ranking is by absolute movement descending, so if any area moved at all the top row
  # is one that did. A false here is therefore a claim about every area the comparison covered.
  def any_movement? = rows.any?(&:moved?)

  # At least one LISTED area did not move. The ranking is by absolute movement descending and the
  # list is capped, so unmoved areas can only appear in its tail — exactly when fewer areas moved
  # than the cap has room for. Not a defect (the reader is seeing where the movement ran out) but it
  # does mean a list headed "the areas that moved most" can hold areas that did not move, so the
  # caption has a clause for it and this is what decides whether that clause is true.
  def any_unmoved? = rows.any? { |row| !row.moved? }

  # One directory's movement across the window, and both operands it was taken across.
  #
  # A SUBCLASS of the last-push panel's row rather than a second Struct with the same members, and
  # the inheritance is the point: `#change_label` — which glyph a negative movement wears, what an
  # area present on only one side says instead of a delta, and that an unmoved area reads `±0`
  # rather than `+0` — is one spelling for both panels, and these two columns sit under one another
  # on the same page in the same `tabular-nums` alignment. A copy would be two spellings of a
  # typographic decision that has to agree.
  #
  # What is overridden is exactly what genuinely differs: every sentence naming WHAT the movement
  # was measured against. "Than the previous run on this branch" is false of a figure taken across
  # twenty-six runs, and a reading that says it would be the panel's one claim a reader cannot check
  # against the table.
  #
  # `previous_count` and `latest_count` keep the parent's names — they are the aggregate's own two
  # sides — and read as the BASELINE end and the ANCHOR end here. The two aliases below are what the
  # template says, so nothing rendering this panel has to hold that translation in its head.
  class Row < SpecDirectoryGrowth::Row
    def baseline_count_label = previous_count_label

    def anchor_count_label = latest_count_label

    # The same fact in words, for the `aria-label` on that cell — the movement's direction and what
    # it was measured against, spelled out because U+2212 is announced inconsistently across screen
    # readers (from "minus" to nothing at all) and a row of unattached numbers is not a sentence.
    #
    # Every branch names the BASELINE rather than "the previous run", and the difference is not
    # cosmetic: this figure spans the window, and a screen-reader user who is told it is a change
    # since the last push has been given the wrong measurement, not merely a vaguer one.
    def change_reading
      return "#{example_phrase(latest_count)}, an area the baseline run did not record" if new_area?
      return "#{example_phrase(previous_count)} in the baseline run and none now" if removed_area?
      return "unchanged since the baseline run of this window" unless moved?

      "#{example_phrase(change.abs)} #{change.negative? ? "fewer" : "more"} " \
        "than the baseline run of this window"
    end
  end
end
