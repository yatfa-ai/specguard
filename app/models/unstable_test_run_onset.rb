# frozen_string_literal: true

# THE REGRESSION ONSET of one unstable test's run-by-run sequence — the last run that passed and
# the first that failed, computed over rows already loaded, or the specific reason this sequence's
# shape does not support naming one.
#
# `UnstableTestsHelper#unstable_test_runs_reading_sentence` has always told the reader to find "the
# first failing row after the last row that passed" and build a GitHub range from it by hand — a
# scan over up to 200 rows, done in the reader's head, with the compare range assembled from two
# printed shas. This object mechanizes exactly that reading and NOTHING beyond it: where the shape
# supports the two rows, it hands them back; where it does not, it says which arm of the reading
# rule failed, because an onset a reader cannot see is worthless but an onset the panel refuses
# silently is the same full-looking absence the cap alert exists to prevent. The partial renders a
# line for every answer — offered, "predates this window", or withheld with its reason — never for
# none.
#
# == What a named onset claims, and the ceiling on the claim
#
# Two runs of this window: one whose rows all passed, and the next run in the window whose rows all
# failed. That is ALL it claims. It is evidence about two OBSERVED runs — "between these two runs
# the test went from passing to failing" — and the compare range the view builds from them is a
# candidate set, never "this commit broke it": `Repository#github_commit_url`'s warning about row
# adjacency applies to this pair too, and the linear-history caveat for rebased and force-pushed
# branches is stated beside the link rather than hoped away.
#
# == Every withhold arm, and why each one refuses
#
# The onset is offered only when ALL of these hold; each failure has its own reason, and the
# reasons are distinct because they send the reader to different work:
#
# * `:capped` — the cap took rows (`recorded_count > rows.size`, the same predicate
#   `#unstable_test_runs_capped?` states once). This window keeps its OLDEST rows, so the end of
#   the list is not the end of the window's evidence, and the trailing failing block an onset is
#   read from may not be on the page at all. The cap alert beside it already says what was kept;
#   this arm exists so the onset line AGREES with it rather than answering a question the alert
#   just withdrew.
# * `:mixed_run` — some run carries this description under more than one example and its rows did
#   not agree (one passed, one failed). The description is not a key within a run — a table-driven
#   loop — so no single outcome describes that run, and every run-grain reading below (block,
#   boundary) is undefined until this arm has refused.
# * `:same_commit` — one `commit_sha` appears with both a passed and a failed row ANYWHERE in the
#   window. That is direct flake evidence — the same code both passed and failed this test — and
#   naming an onset between two runs of one commit would be naming a range GitHub renders as an
#   empty diff. Said instead of offered, per the arm's own instruction.
# * `:nothing_reported` — no row in the window reported an outcome at all. There is no sequence to
#   read; the silence clause beside it counts the rows.
# * `:newest_not_failed` — the newest row that reported an outcome did not fail. A window that ends
#   in a pass has no trailing failing block for an onset to close, whatever happened earlier in it.
# * `:scattered` — the failing runs do not form one contiguous trailing block: some run OLDER than
#   the last passing run also failed. This is the flakiness shape the reading sentence describes —
#   failures at runs 3, 11, 19 and 26 — and it withholds even though the newest run failed, because
#   the last failure of a scattered window is not the onset of anything.
# * `:ambiguous_boundary` — the pass→fail boundary itself is not cleanly observed: a run sits
#   between the last pass and the first failure that reported no outcome (or an outcome this panel
#   does not read), or one of the two boundary runs carries rows that did not all report the same
#   word. The flip between the two runs is the whole claim; an unobserved row sitting on it
#   unobserves the claim.
#
# `failing_since_window_start` is NOT a withhold: every reported row failed, so the honest answer
# is that any onset predates this window — offered as its own result, with no compare range,
# because there is no passing run on this side of it to range from.
#
# == Shape of the answer
#
# One of three results, checked with `#onset?` / `#failing_since_window_start?` / `#withheld?`:
#
#   UnstableTestRunOnset::Onset                     — `#last_pass_row` and `#first_fail_row`,
#                                                     both `UnstableTestRuns::Row`
#   UnstableTestRunOnset::FailingSinceWindowStart   — no rows; the copy carries the whole answer
#   UnstableTestRunOnset::Withheld                  — `#reason`, one of the symbols above; prose
#                                                     lives in the helper
#
# The reasons are KEYS here and sentences in `UnstableTestsHelper`, on the standing rule this
# ladder's drill-ins follow — the object serves operands, the surface states the reading.
#
# == The window's order is an assumption, stated rather than verified
#
# The walk reads POSITION off `sequence.rows`, and this object does not re-sort: `UnstableTestRuns`
# is order-propagating and the web panel hands it the OLDEST-first window
# (`Repository#suite_size_trajectory` — the "Suite growth" chart's direction, and the direction the
# scope sentence beside this line states). The presenter is therefore rendered only beside that
# window, and a future caller with a newest-first window must hand it a re-oriented sequence rather
# than expect this object to guess.
#
# == Pure, and priced accordingly
#
# No query, no I/O of any kind: rows, `recorded_count` and the runs' `commit_sha` are already on
# the objects the page loaded, the walk is O(rows), and the compare URL the view composes from the
# two shas is string composition — so the line costs the page nothing, and the page-bytes and
# query-count pins in `spec/requests/repository_unstable_test_runs_spec.rb` hold unchanged.
class UnstableTestRunOnset
  PASS = "passed"
  FAIL = "failed"

  # The reasons a withhold can name, kept as a list so a typo'd key is an error at the use site
  # rather than a silently-unhandled branch in the view.
  REASONS = %i[capped mixed_run same_commit nothing_reported newest_not_failed scattered
               ambiguous_boundary].freeze

  # The one entry point. Takes the loaded `UnstableTestRuns` and answers with one of the three
  # results; see the class comment for the arms, in the order they are checked.
  def self.for(sequence)
    rows = sequence.rows
    return Withheld.new(:nothing_reported) if rows.empty?

    return Withheld.new(:capped) if capped?(sequence)
    return Withheld.new(:mixed_run) if mixed_run?(rows)
    return Withheld.new(:same_commit) if same_commit_flake?(rows)

    reported = rows.select { |row| row.outcome }
    return Withheld.new(:nothing_reported) if reported.empty?
    return Withheld.new(:newest_not_failed) unless reported.last.outcome == FAIL

    # Every row that said anything said failed: there is no pass on this side of the window, so the
    # last pass this window saw is none. Offered — "predates this window" is an answer — and not a
    # withhold, because the sequence's shape supports it better than any withhold reason would.
    return FailingSinceWindowStart.new if reported.all? { |row| row.outcome == FAIL }

    last_pass_row, first_fail_row = boundary_of(rows)
    return Withheld.new(:ambiguous_boundary) if last_pass_row.nil?

    return Withheld.new(:scattered) if scattered?(rows, last_pass_row)

    Onset.new(last_pass_row: last_pass_row, first_fail_row: first_fail_row)
  end

  # An onset the two boundary runs carry. The view links both ends and ranges between them; the
  # pair is always two DIFFERENT shas when reached through `.for` — a shared sha with both outcomes
  # is the `:same_commit` arm — but the view keeps its own guard on that, because "show the compare
  # only when the ends differ" is the view's sentence to make.
  class Onset
    attr_reader :last_pass_row, :first_fail_row

    def initialize(last_pass_row:, first_fail_row:)
      @last_pass_row = last_pass_row
      @first_fail_row = first_fail_row
    end

    def onset? = true

    def failing_since_window_start? = false

    def withheld? = false

    def reason = nil
  end

  # Every run that reported an outcome failed, so the last pass this window saw is none — if this
  # test has an onset, it predates the window. No rows are carried: there is no passing run on this
  # side of it to link or to range from.
  class FailingSinceWindowStart
    def onset? = false

    def failing_since_window_start? = true

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

    def onset? = false

    def failing_since_window_start? = false

    def withheld? = true
  end

  # The cap, asked of the operands the helper's `#unstable_test_runs_capped?` asks of the same
  # ones. Restated here rather than reached for across the helper boundary — a presenter cannot
  # call a view helper, and the comparison is one line of arithmetic over counts this object
  # already holds.
  def self.capped?(sequence)
    sequence.recorded_count > sequence.rows.size
  end

  # Any run whose own rows disagree. Grouped by RUN id, not by sha: a re-ingested commit is
  # legitimately two runs, and it is the `:same_commit` arm below that speaks about those.
  def self.mixed_run?(rows)
    rows.group_by(&:test_run_id).each_value.any? do |run_rows|
      outcomes = run_rows.filter_map(&:outcome)
      outcomes.include?(PASS) && outcomes.include?(FAIL)
    end
  end

  # Any commit whose rows disagree ACROSS runs — the direct flake evidence. "Anywhere in the
  # window" is deliberate: a sha that both passed and failed the test somewhere in the window
  # undermines the regression reading wherever the onset would have sat, because the code cannot
  # both have done and not done this.
  def self.same_commit_flake?(rows)
    rows.group_by(&:commit_sha).each_value.any? do |sha_rows|
      outcomes = sha_rows.filter_map(&:outcome)
      outcomes.include?(PASS) && outcomes.include?(FAIL)
    end
  end

  # The pass→fail boundary, walked at run grain from the window's newest end. Returns
  # `[last_pass_row, first_fail_row]`, or `[nil, nil]` when the boundary is not cleanly observed —
  # the one `:ambiguous_boundary` arm, whichever way it fails.
  #
  # The trailing block extends back through runs that failed (and failed ONLY — the mixed arm has
  # already refused the disagreeing ones, so a block run cannot carry a passed row). The walk stops
  # at the first run that passed:
  #
  # * A run with neither outcome (all-silent, or rows reporting some word this panel does not read)
  #   refuses the walk whether it sits mid-stretch or after it: mid-stretch, the failing stretch is
  #   not observed through it; at the window's end, the failure is not observed to be trailing.
  #   Silence is not a pass and is not counted as one here — the panel's own rule, applied at the
  #   boundary where counting it as either would manufacture an answer.
  # * The run that passed must have EVERY row passed, and the first failing run must have EVERY row
  #   failed. Both are stricter than the reading sentence's row-grain wording, and deliberately so:
  #   a boundary run carrying a row that reported nothing leaves a silent row sitting exactly
  #   between the pass and the failure, which is the arm this refusal exists for.
  def self.boundary_of(rows)
    runs = rows.group_by(&:test_run_id)

    block_run_ids = []
    last_pass_run_id = nil
    runs.keys.reverse_each do |run_id|
      outcomes = runs.fetch(run_id).filter_map(&:outcome)
      if outcomes.include?(FAIL)
        block_run_ids << run_id
      elsif outcomes.include?(PASS)
        last_pass_run_id = run_id
        break
      else
        return [nil, nil]
      end
    end

    return [nil, nil] if last_pass_run_id.nil?
    return [nil, nil] unless runs.fetch(last_pass_run_id).all? { |row| row.outcome == PASS }

    first_fail_run_id = block_run_ids.last
    return [nil, nil] unless runs.fetch(first_fail_run_id).all? { |row| row.outcome == FAIL }

    [runs.fetch(last_pass_run_id).first, runs.fetch(first_fail_run_id).first]
  end

  # The flakiness shape: a failure OLDER than the last passing run. The trailing block and its
  # boundary may both be perfectly clean and this still refuses, because failures scattered
  # through the window mean the newest failure is the latest failure and not the first one — the
  # acceptance case the reading sentence calls "failures scattered through the list".
  def self.scattered?(rows, last_pass_row)
    boundary_index = rows.index { |row| row.equal?(last_pass_row) }
    rows.first(boundary_index).any? { |row| row.outcome == FAIL }
  end
end
