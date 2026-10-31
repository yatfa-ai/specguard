# frozen_string_literal: true

# THE DURATION STEP-UP of one test's run-by-run sequence — the largest run-over-run rise between
# two consecutive timed runs, with the pace the rest of the window kept around it, computed over
# rows already loaded; or the specific reason this sequence's shape does not support naming one.
#
# A sibling of `UnstableTestRunOnset` answering a question that onset cannot: the panel's flakiness
# reading withholds `:newest_not_failed` on exactly the test this line exists for — the green test
# that steadily passes and got slow. Where the onset reads OUTCOMES, this reads DURATIONS, so a
# window whose every row passed still earns a step when the pace jumped. The panel renders this
# line only for a test opened from a slowest-tests ranking (`?unstable_test_from=slowest-examples`
# — the reader arriving that way wants to know when the test got slow, not when it broke), and the
# view's gate keeps every other origin's page byte-identical to what it was.
#
# == How a run's duration is computed, and why the rule is the sum
#
# Rows are reduced to RUN grain before anything is compared, over rows that carry a duration: a
# run contributes the SUM of its timed rows, and a run none of whose rows carries a duration is
# untimed and sits outside the sequence. The sum is chosen over withholding multi-row runs on
# purpose, and the choice is stated in the panel's reading sentence rather than left in this
# comment: a description carried by several examples in a run is an ordinary table-driven loop,
# and withholding on it would silence this line for exactly the parameterized suites where pace
# moved most. The sum is that description's total cost to the run — not one example's measurement,
# and the copy says so — while the Duration column beside it stays per-row, which is why the two
# figures are allowed to disagree.
#
# == What a named step claims, and the ceiling on the claim
#
# Two runs of this window, consecutive among the timed ones: one whose total under this
# description was lower, and the next timed run whose total was higher. That is ALL it claims —
# the same narrow claim the onset makes about its own pair. The compare range the view builds from
# the two shas is a candidate set, never "this commit slowed it down": runs are not commits
# (`Repository#github_compare_url`'s contract states the discipline both lines borrow), and the
# linear-history caveat for rebased and force-pushed branches is stated beside the link rather
# than hoped away.
#
# == Every withhold arm, and why each one refuses
#
# A step is offered only when ALL of these hold; each failure has its own reason, and the reasons
# are distinct because they send the reader to different work:
#
# * `:capped` — the cap took rows (`recorded_count > rows.size`, the same predicate the panel's
#   cap alert states once). This window keeps its OLDEST rows, so the newest end of the sequence —
#   the end a pace is read from — is not on the page, and a "largest step" named off a truncated
#   end would be a step named off the wrong half of the evidence. The cap arm is checked before
#   anything else, so the line refuses for the same reason the alert above it states and the two
#   cannot disagree about whether the cap bit.
# * `:too_few_timed_runs` — fewer than `MIN_TIMED_RUNS` runs of this window timed the description.
#   Two timed runs are a single interval, and one interval cannot be told apart from the test
#   simply being that slow: there is no pace for a rise to step up from.
# * `:no_rise` — no consecutive pair of timed runs rose. The window got faster or held steady
#   throughout; there is no step up to name.
# * `:untimed_between` — a run sits between the two ends of the largest rise that carried the
#   description but timed none of its rows. The pair is consecutive among TIMED runs, so an
#   untimed run between them would put the whole rise on one transition the window never observed;
#   bridging it would name a step whose two ends are not the runs the change happened between.
# * `:same_commit` — the two ends of the largest rise are runs of the same commit. That is one
#   commit measured twice (a re-run, a retry), not a transition, and a compare range between a
#   commit and itself is an empty diff. Unlike the onset's same-commit arm, this one is about the
#   boundary pair only — the same sha elsewhere in the window says nothing about whether the pace
#   stepped up between two different commits.
#
# == Shape of the answer
#
# One of two results, checked with `#offered?` / `#withheld?`:
#
#   UnstableTestRunDurationStep::Step     — `#from_row` / `#to_row` (`UnstableTestRuns::Row`,
#                                           the pair's runs) beside `#from_seconds` /
#                                           `#to_seconds` (the run totals the step is between) and
#                                           the window's pace figures `#fastest_seconds`,
#                                           `#median_seconds`, `#newest_seconds`,
#                                           `#slowest_seconds`
#   UnstableTestRunDurationStep::Withheld — `#reason`, one of the symbols above; prose lives in
#                                           `UnstableTestsHelper`
#
# The reasons are KEYS here and sentences in `UnstableTestsHelper`, on the standing rule this
# ladder's drill-ins follow — the object serves operands, the surface states the reading.
#
# == The window's order is an assumption, stated rather than verified
#
# The walk reads POSITION off `sequence.rows`, and this object does not re-sort: `UnstableTestRuns`
# is order-propagating and the web panel hands it the OLDEST-first window (the direction the
# "Suite growth" chart is plotted in). "Newest" and "the end of the sequence" mean the LAST timed
# run under that orientation, and a future caller with a newest-first window must hand it a
# re-oriented sequence rather than expect this object to guess. The panel renders it only beside
# that window, as the onset's own comment already states for the pair of them.
#
# == Pure, and priced accordingly
#
# No query, no I/O of any kind: rows, `recorded_count` and the runs' `commit_sha` are already on
# the objects the page loaded, the walk is O(rows), and the compare URL the view composes from the
# two shas is string composition — so the line costs the page nothing, and the page-bytes and
# query-count pins in `spec/requests/repository_unstable_test_runs_spec.rb` hold unchanged.
class UnstableTestRunDurationStep
  # The smallest timed-run count a step can be offered over, and WHY it is three: two timed runs
  # are one interval, and a single interval has nothing to be a "largest" step against — any two
  # runs differ from each other by definition. A third timed run is the smallest population a
  # pace can be read from.
  MIN_TIMED_RUNS = 3

  # The reasons a withhold can name, kept as a list so a typo'd key is an error at the use site
  # rather than a silently-unhandled branch in the view.
  REASONS = %i[capped too_few_timed_runs no_rise untimed_between same_commit].freeze

  # The one entry point. Takes the loaded `UnstableTestRuns` and answers with one of the two
  # results; see the class comment for the arms, in the order they are checked.
  def self.for(sequence)
    return Withheld.new(:capped) if capped?(sequence)

    entries = run_entries(sequence.rows)
    timed = entries.select(&:timed?)
    return Withheld.new(:too_few_timed_runs) if timed.size < MIN_TIMED_RUNS

    from, to = largest_positive_step(timed)
    return Withheld.new(:no_rise) unless from

    return Withheld.new(:untimed_between) if untimed_between?(entries, from, to)
    return Withheld.new(:same_commit) if from.row.commit_sha == to.row.commit_sha

    Step.new(from_row: from.row, to_row: to.row, from_seconds: from.seconds, to_seconds: to.seconds,
             fastest_seconds: timed.map(&:seconds).min, slowest_seconds: timed.map(&:seconds).max,
             median_seconds: median(timed.map(&:seconds)), newest_seconds: timed.last.seconds)
  end

  # The step the two boundary runs carry. The view links both ends and ranges between them; the
  # pair is always two DIFFERENT shas when reached through `.for` — a shared sha on the boundary
  # is the `:same_commit` arm — but the view keeps its own guard on that, because "show the
  # compare only when the ends differ" is the view's sentence to make, as it already does for the
  # onset's pair.
  class Step
    attr_reader :from_row, :to_row, :from_seconds, :to_seconds,
                :fastest_seconds, :median_seconds, :newest_seconds, :slowest_seconds

    def initialize(from_row:, to_row:, from_seconds:, to_seconds:, fastest_seconds:, median_seconds:,
                   newest_seconds:, slowest_seconds:)
      @from_row = from_row
      @to_row = to_row
      @from_seconds = from_seconds
      @to_seconds = to_seconds
      @fastest_seconds = fastest_seconds
      @median_seconds = median_seconds
      @newest_seconds = newest_seconds
      @slowest_seconds = slowest_seconds
    end

    def offered? = true

    def withheld? = false

    def reason = nil
  end

  # The reading rule refused this window, for the named reason. The prose for each reason lives in
  # `UnstableTestsHelper`, where every other sentence of this panel lives.
  class Withheld
    attr_reader :reason

    def initialize(reason)
      raise ArgumentError, "unknown withhold reason: #{reason.inspect}" unless REASONS.include?(reason)

      @reason = reason
    end

    def offered? = false

    def withheld? = true
  end

  # The cap, asked of the operands the helper's `#unstable_test_runs_capped?` asks of the same
  # ones. Restated here rather than reached for across the helper boundary — a presenter cannot
  # call a view helper, and the comparison is one line of arithmetic over counts this object
  # already holds; the onset presenter makes the same restatement for the same reason.
  def self.capped?(sequence)
    sequence.recorded_count > sequence.rows.size
  end

  # One entry per run that recorded the description, in the rows' own order — the window's order,
  # whatever orientation it was handed in with. An entry is `timed?` when ANY of the run's rows
  # carries a duration, and its `seconds` is the sum of the timed ones (the run-grain rule the
  # class comment states); the row kept beside the total is any row of the run, because the only
  # fields read off it — `commit_sha` and the run the link returns into — are the run's own, not
  # the example's.
  def self.run_entries(rows)
    rows.group_by(&:test_run_id).map do |test_run_id, run_rows|
      durations = run_rows.filter_map(&:duration_seconds)
      Entry.new(test_run_id: test_run_id, row: run_rows.first,
                seconds: durations.any? ? durations.sum : nil)
    end
  end

  Entry = Struct.new(:test_run_id, :row, :seconds, keyword_init: true) do
    def timed? = !seconds.nil?
  end
  private_constant :Entry

  # The largest run-over-run RISE between consecutive timed entries, earliest occurrence winning a
  # tie. Returns the pair `[from, to]`, or nil when no pair rose — the `:no_rise` arm. Scanning
  # `each_cons(2)` over the timed entries keeps the comparison consecutive-by-construction: a
  # step is only ever read between runs with no other timed run in between, which is what makes
  # the `:untimed_between` arm the only gap this walk can leave behind.
  def self.largest_positive_step(timed)
    best = nil
    best_rise = 0.0
    timed.each_cons(2) do |from, to|
      rise = to.seconds - from.seconds
      next unless rise > best_rise

      best = [from, to]
      best_rise = rise
    end
    best
  end

  # Whether an untimed run sits between the two boundary entries in the window's order. The pair
  # is consecutive among TIMED entries, so `from` always precedes `to`, and every entry the slice
  # between them holds is an entry the timed sequence skipped — an untimed run, if any is there.
  # Reading the gap off the full entry list is what keeps the check honest about runs that
  # recorded the description without timing it.
  def self.untimed_between?(entries, from, to)
    entries[(entries.index(from) + 1)...entries.index(to)].any? { |entry| !entry.timed? }
  end

  # The median of the timed totals — the pace half the window's timed runs sat under. An even
  # count averages its middle pair.
  def self.median(values)
    sorted = values.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end
end
