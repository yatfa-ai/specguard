# frozen_string_literal: true

# ONE unstable test, run by run — the rows behind a single line of the "Tests whose outcome changed"
# ranking, together with everything the surface listing them has to state about the window they were
# drawn from.
#
# The fourth drill-in on this endpoint and the rung directly below `UnstableTests`, exactly as
# `RepeatedDescriptionExamples` sits below `RepeatedDescriptions` and `SpecFileExamples` below the
# by-file rollup. It is not a new kind of thing; it is the one rung the flakiness ladder never had.
#
# == The distinction this exists to make, which the ranking above CANNOT make
#
# A row of that ranking says `run_count: 30`, `failed_run_count: 4`, `outcome_words: ["failed",
# "passed"]`. Those three figures are identical for two windows that call for opposite work:
#
#   - the four failures were runs 27–30 — a REGRESSION. Something landed. The fix is to find the
#     commit between run 26 and run 27 and look at it. The test is not flaky at all; it fails
#     deterministically, on code that changed.
#   - the four failures were runs 3, 11, 19 and 26 — FLAKINESS. Nothing landed. The fix is
#     quarantine, retry, or hunting the shared state, and there is no culprit commit to find.
#
# `UnstableTests` cannot tell them apart and is right not to try: `SpecObservation::UNSTABLE_COMPOSITION`
# is every column a `COUNT` or an `ARRAY_AGG(DISTINCT …)` under `GROUP BY name`, which is the correct
# shape for a RANKING and is what keeps it constant in the size of the suite.
# `UnstableTests::Row#outcome_words` then sorts the distinct set, discarding even arrival order — on
# purpose, so two rows carrying the same set read the same way. The run axis is gone before the row
# is built, and nothing above this object ever had it.
#
# Nor is it derivable from anything else the surfaces serve. `history` rows carry `commit_sha`,
# `branch` and `ingested_at` and have NO per-test grain; `spec_file_examples` and
# `repeated_description_examples` carry an `outcome` for the LATEST RUN only. A client holds at most
# one run's outcome per test beside thirty-run aggregates, and no amount of arithmetic over those two
# produces a sequence.
#
# == Why the list and its captions are one object
#
# `SlowestExamples` states the rule, `SpecFileExamples` repeats it and `RepeatedDescriptionExamples`
# repeats it again: a caption is a claim ABOUT the list. "34 rows over the last 30 runs on main, 31
# of which reported an outcome" is only true if all three figures were counted off the same window
# the rows were taken from. Fetched separately they are figures that agree today with no structural
# reason to keep agreeing — and this object is the one place on the ladder where they could most
# easily come apart, because the window is handed IN rather than queried here.
#
# It derives no figure of its own. The two population counts ride back on the listed rows as window
# counts (`SpecObservation::UNSTABLE_TEST_RUN_POPULATION_COUNTS`) and the window's length is the
# length of the runs it was given.
#
# == The window is HANDED IN, never re-queried
#
# `UnstableTests.for`'s own parameter documentation makes this argument and it binds harder here, not
# less: two panels that separately fetched "the last thirty runs on this branch" are two windows that
# agree today, and this one's rows are read for their POSITION in a window whose other half — the
# `commit_sha` a reader joins against — was serialized from the first fetch. A second fetch would put
# an off-by-one between the sequence and the commits it is read against, which is the one error this
# drill-in cannot survive: naming the wrong culprit commit is worse than naming none.
#
# == A test the window recorded nothing for is not an error
#
# `?unstable_test=` is a URL a reader types, edits and bookmarks, and a window that recorded nothing
# under the description they ask for is an ordinary answer rather than a malformed request: a test
# renamed since — which per the project's semantic-identity rule STARTS A NEW HISTORY and so is
# exactly how a bookmark goes stale — a description edited, a typo. `.for` returns an object with no
# rows and the surface says so, which is the same shape `RepeatedDescriptionExamples` answers with
# one ladder over.
class UnstableTestRuns
  def self.for(repository, runs, name, limit: SpecObservation::UNSTABLE_TEST_RUNS_LIMIT)
    new(name: name, runs: runs,
        observations: SpecObservation.outcome_sequence_in(
          repository_id: repository.id, run_ids: runs.map(&:id), name: name, limit: limit
        ).to_a)
  end

  def initialize(name:, runs:, observations:)
    @name = name
    @run_count = runs.size
    # The read is ordered by the window's own order and is NOT re-sorted here — see
    # `SpecObservation.outcome_sequence_in`, where that ordering is the point. Paired against the
    # loaded runs by id rather than re-fetched, so a row's identity is the identity the `history`
    # block serialized from the same objects.
    #
    # `fetch` rather than `[]`, and it cannot raise: the read narrows on `test_run_id IN (run_ids)`,
    # so every observation belongs to a run of this map by construction. It is `fetch` so that a
    # future caller handing in a window narrower than the one it queried gets a crash naming the
    # mismatch rather than a row serving a `nil` commit under a real outcome.
    by_run = runs.index_by(&:id)
    @rows = observations.map do |observation|
      Row.new(run: by_run.fetch(observation.test_run_id), observation: observation)
    end
  end

  # The description that was asked for, as the server read it. Held even when nothing came back,
  # because the empty answer has to name its subject — "no runs" without one is a sentence about
  # nothing, and here the subject is a sentence somebody wrote, which is the one thing a reader can
  # check against their own suite.
  attr_reader :name

  # This description's rows across the window, in window order — newest run first. One row per run is
  # what the data USUALLY is rather than a promise this list makes, and it comes apart in both
  # directions: a run that recorded nothing under this description contributes NO row — the case
  # `#run_count` below states, where a test added halfway through the window has fifteen rows in a
  # window of thirty — and a description carried by more than one example in a run contributes one
  # row per example. So `rows.length` is neither `run_count` nor bounded below by it, and the run a
  # row belongs to is read off its `test_run_id` / `commit_sha` and never off its index. Never longer
  # than the limit it was built with.
  attr_reader :rows

  # How many runs THE WINDOW holds — the denominator every claim about this sequence is worded
  # against, and not the number of runs that recorded the test. A test added halfway through the
  # window has fifteen rows in a window of thirty, and both numbers are facts a reader needs: the
  # second is `rows.length`, and it is the ranking above that reports it as `run_count` at the ROW
  # grain. The block grain means the window on both objects, which is the convention
  # `UnstableTests#run_count` already sets.
  attr_reader :run_count

  # How many rows the window holds under this description IN TOTAL, and how many of them reported an
  # outcome at all — both counted before the cap, so neither describes the listed head rather than
  # the sequence.
  #
  # Read off any row, because the windows carry the same two figures on all of them; `to_i` over the
  # nil of an empty read, where zero is the honest count. The "read it off whichever row you have"
  # shape both sibling drill-ins use.
  def recorded_count = window_count("unstable_test_recorded_count")

  def reported_outcome_count = window_count("unstable_test_reported_outcome_count")

  # Rows the window recorded here that said NOTHING about how the test ended. Not a pass, and
  # counted as one nowhere: `UnstableTests::Row#changed?` compares against `reported_outcome_count`
  # rather than `recorded_count` precisely so a client that stopped sending outcomes cannot
  # manufacture a flip, and a sequence that let those rows read as passes would manufacture the same
  # flip one rung down, where it would look like a date. Counted over the WINDOW rather than over the
  # listed rows, so a truncated list's silence is still countable.
  def unreported_outcome_count = recorded_count - reported_outcome_count

  # ONE run's record of this description: the run's identity beside what that run said about the
  # test. Two objects rather than a flattened copy of either, because every field here has exactly
  # one source — `commit_sha` is the RUN's and `outcome` is the OBSERVATION's — and a struct that
  # copied them would be a second place for the two to disagree.
  Row = Struct.new(:run, :observation, keyword_init: true) do
    # The run this row belongs to. `test_run_id` is served beside the commit because a commit is not
    # a key — the same commit is legitimately ingested more than once (a re-run, a retry, a second
    # CI workflow), and a reader following a sequence needs to be able to tell two runs of one
    # commit apart.
    def test_run_id = run.id

    def commit_sha = run.commit_sha

    # Per-row, on the rule `Api::V1::RepositoriesController#serialized_history_row` states for the
    # same field: a row should carry its own branch rather than borrow it from the window it
    # arrived in. Every row here carries the same value — the window is branch-scoped by
    # construction — and it is served anyway, so a row is readable on its own.
    def branch = run.branch

    def ingested_at = run.created_at

    # ECHOED VERBATIM and never reworded into a verdict, on the model's own echo-don't-judge rule:
    # nothing platform-side validates this string (`SpecObservation#outcome_label`), so quoting what
    # arrived is the only reading that cannot be wrong. An unrecognised word goes out unrecognised,
    # and a run that reported none goes out as a nil rather than as anything.
    def outcome = observation.outcome

    def duration_seconds = observation.duration_seconds

    # WHERE THE TEST RAN IN THIS RUN, which is a per-row fact and not a constant of the sequence.
    # Per the project's semantic-identity rule a test that MOVED is the same test and keeps its
    # history, so these may differ down the list — `UnstableTests::Row#multi_file?` discloses that
    # one rung up as a boolean, and this is the same disclosure with the run it happened in.
    def spec_file_path = observation.spec_file_path

    def line_number = observation.line_number
  end

  private

  # `to_i` over `nil` twice: over the empty read that has no row to carry a window, and over the
  # attribute itself, since a count arriving as anything but an Integer must still leave the figures
  # above doing arithmetic on integers.
  def window_count(attribute) = rows.first&.observation&.[](attribute).to_i
end
