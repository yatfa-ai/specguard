# frozen_string_literal: true

require "rails_helper"

# The presenter that mechanizes the pace reading of the "This test, run by run" panel — the
# largest run-over-run step up between consecutive timed runs, the window's pace around it, or
# the specific arm of the rule that refuses this window.
#
# Bare structs stand in for runs and observations here, on the precedent the sibling onset
# spec set: what is under test is which run grain the walk picks and which arm fires, and none of
# that reads anything a real record carries beyond `commit_sha`, `test_run_id` and
# `duration_seconds`. The sequences are built through `UnstableTestRuns` itself rather than
# around it, so the rows under test are the `Row` structs the panel actually hands over.
#
# OUTCOMES ARE NOT THIS PRESENTER'S INPUT, and the fixtures lean on that deliberately: every
# observation below carries the same outcome word (or none at all), because the test this line
# exists for is the green one that steadily passes and got slow. An outcome-driven fixture here
# would assert a dependency the presenter must not have.
#
# The one behavioural fact every example below leans on, stated here rather than re-derived per
# example: the rows are OLDEST RUN FIRST, because the web panel's window is (`Repository#
# suite_size_trajectory` — the direction the "Suite growth" chart is plotted in and the scope
# sentence on the page states). "Newest" means the LAST timed run under that orientation. A
# fixture in the other orientation would test a window this presenter is never rendered beside.
#
# The stand-ins carry the STEP prefix rather than the sibling onset spec's bare `Run` /
# `Observation`, and the reason is a Ruby scoping fact rather than style: a constant assigned
# inside a `describe` block lands on the file's top-level namespace, so a second same-named pair
# would redefine the sibling's fixtures mid-suite and warn while doing it.
RSpec.describe UnstableTestRunDurationStep do
  StepRun = Struct.new(:id, :commit_sha, :branch, :created_at, keyword_init: true)
  StepObservation = Struct.new(:test_run_id, :outcome, :duration_seconds, :spec_file_path,
                               :line_number, :unstable_test_recorded_count,
                               :unstable_test_reported_outcome_count, keyword_init: true)

  def sha_for(index) = "#{format("%02d", index)}c0ffee0000"

  # One sequence from durations per run, oldest run first. Each entry is one run: a plain value is
  # that run's single timed row, an array is several rows in one run (the table-driven shape the
  # sum rule is about), and nil is a row that recorded the test with no duration — all three are
  # states the real read produces. Outcomes are pinned to a constant pass on every row: this
  # presenter reads time, not outcome, and a fixture that varied outcomes would suggest otherwise.
  # The window counts are stamped on every observation the way the real read stamps them, so the
  # cap check reads the same operands off whichever row it asks.
  def sequence_for(durations_per_run, shas: nil, recorded_count: nil)
    shas ||= durations_per_run.each_index.map { |index| sha_for(index) }
    runs = durations_per_run.each_index.map do |index|
      StepRun.new(id: index + 1, commit_sha: shas[index], branch: "main", created_at: Time.current)
    end
    total = durations_per_run.sum { |per_run| per_run.is_a?(Array) ? per_run.size : 1 }

    observations = runs.each_with_index.flat_map do |run, index|
      durations = durations_per_run[index].is_a?(Array) ? durations_per_run[index] : [durations_per_run[index]]
      durations.map do |duration|
        StepObservation.new(test_run_id: run.id, outcome: "passed", duration_seconds: duration,
                        spec_file_path: "spec/models/invoice_spec.rb", line_number: 1,
                        unstable_test_recorded_count: recorded_count || total,
                        unstable_test_reported_outcome_count: total)
      end
    end

    UnstableTestRuns.new(name: "Invoice finalize locks the line items", runs: runs,
                         observations: observations)
  end

  # THE ANSWER IT EXISTS FOR. Durations [1.0, 1.1, 1.0, 4.2, 4.3] — the pace this line is read
  # for: steady around one second, then a jump to four. The largest rise is run 3 → run 4, and
  # the pair is named by its own runs' commits with the two totals the rise is between.
  # @intent: {"entity": "UnstableTestRunDurationStep", "action": "name the step", "behavior": "durations 1.0 1.1 1.0 4.2 4.3 return a step from run 3 at 1.0s to run 4 at 4.2s, each named by its own run's commit", "layer": "unit"}
  it "names the largest rise between consecutive timed runs, by its own two runs" do
    step = described_class.for(sequence_for([1.0, 1.1, 1.0, 4.2, 4.3]))

    expect(step).to be_offered
    expect(step.from_row.commit_sha).to eq(sha_for(2))
    expect(step.from_seconds).to eq(1.0)
    expect(step.to_row.commit_sha).to eq(sha_for(3))
    expect(step.to_seconds).to eq(4.2)
    expect(step).not_to be_withheld
  end

  # A tie on the largest rise is broken toward the EARLIEST pair, so two sessions reading the same
  # window name the same runs — the step is a fact about the window and not about scan order.
  # @intent: {"entity": "UnstableTestRunDurationStep", "action": "break ties earliest", "behavior": "two equal rises return the earlier pair, not the later one", "layer": "unit"}
  it "breaks a tie on the largest rise toward the earliest pair" do
    step = described_class.for(sequence_for([1.0, 2.0, 2.0, 3.0]))

    expect(step.from_row.commit_sha).to eq(sha_for(0))
    expect(step.to_row.commit_sha).to eq(sha_for(1))
  end

  # THE RUN-GRAIN RULE. A run carried under two examples contributes the SUM of its timed rows —
  # the time the description cost that run — so [0.5+0.5, 2.0+2.0] reads as 1.0s → 4.0s. The
  # per-row Duration column beside it shows 0.5s and 2.0s; the two figures are allowed to
  # disagree, and the panel's reading sentence states why.
  # @intent: {"entity": "UnstableTestRunDurationStep", "action": "sum multi-row runs", "behavior": "runs of two timed rows each contribute summed totals, so two-row runs of 0.5s and 2.0s read as 1.0s and 4.0s", "layer": "unit"}
  it "reads a multi-row run at the sum of its timed rows" do
    step = described_class.for(sequence_for([[0.5, 0.5], [2.0, 2.0], [2.0]]))

    expect(step).to be_offered
    expect(step.from_seconds).to eq(1.0)
    expect(step.to_seconds).to eq(4.0)
    expect(step.to_row.commit_sha).to eq(sha_for(1))
  end

  # A run whose client timed SOME of its rows is timed at the sum of the timed ones — an untimed
  # row inside a timed run neither untimes the run nor reads as a zero.
  # @intent: {"entity": "UnstableTestRunDurationStep", "action": "tolerate partial timing", "behavior": "a run carrying one untimed row beside a timed one contributes the timed row's duration alone", "layer": "unit"}
  it "sums only the timed rows of a partially timed run" do
    step = described_class.for(sequence_for([[nil, 1.0], [nil, 4.2], [4.2]]))

    expect(step).to be_offered
    expect(step.from_seconds).to eq(1.0)
    expect(step.to_seconds).to eq(4.2)
  end

  # The pace figures the line carries beside the step, read over the window's timed totals:
  # fastest and slowest are the extremes, the median is the middle timed total, and "newest" is
  # the LAST timed run under the window's oldest-first orientation.
  # @intent: {"entity": "UnstableTestRunDurationStep", "action": "serve pace figures", "behavior": "the step carries fastest 1.0 median 1.1 newest 4.3 slowest 4.3 over the timed totals", "layer": "unit"}
  it "serves the window's fastest, median, newest and slowest timed durations" do
    step = described_class.for(sequence_for([1.0, 1.1, 1.0, 4.2, 4.3]))

    expect(step.fastest_seconds).to eq(1.0)
    expect(step.median_seconds).to eq(1.1)
    expect(step.newest_seconds).to eq(4.3)
    expect(step.slowest_seconds).to eq(4.3)
  end

  # The median of an EVEN timed population averages its middle pair, so a four-run figure is a
  # real median and not a silent truncation to one of the two middle values.
  # @intent: {"entity": "UnstableTestRunDurationStep", "action": "average even median", "behavior": "an even timed population's median is the average of its middle pair", "layer": "unit"}
  it "averages the middle pair for an even timed population" do
    step = described_class.for(sequence_for([1.0, 2.0, 4.2, 4.4]))

    expect(step.median_seconds).to eq(3.1)
  end

  # OUTCOMES ARE NOT INPUT. A window whose rows all failed to report any outcome still earns its
  # step: this line reads time, and the silence the onset line refuses on is not a silence this
  # line inherits.
  # @intent: {"entity": "UnstableTestRunDurationStep", "action": "ignore outcomes", "behavior": "a rising sequence whose rows report no outcome at all still offers its step", "layer": "unit"}
  it "offers the step whatever the outcomes say, including nothing" do
    sequence = sequence_for([1.0, 4.2, 4.3])
    sequence.rows.each { |row| row.observation.outcome = nil }

    expect(described_class.for(sequence)).to be_offered
  end

  describe "each withhold arm" do
    def withheld_reason(durations_per_run, **opts)
      described_class.for(sequence_for(durations_per_run, **opts)).tap do |step|
        expect(step).to be_withheld
      end.reason
    end

    # The cap took the newest rows off this window, so the end the pace is read from is not on
    # the page — the same predicate the panel's cap alert states, refusing before anything else
    # so the line and the alert cannot disagree.
    # @intent: {"entity": "UnstableTestRunDurationStep", "action": "withhold when capped", "behavior": "a sequence whose recorded count exceeds its listed rows withholds :capped even when a rise and three timed runs are on the page", "layer": "unit"}
    it "withholds :capped when the cap took rows off the list" do
      expect(withheld_reason([1.0, 4.2, 4.3], recorded_count: 202)).to eq(:capped)
    end

    # A REAL rise that still refuses: two timed runs are one interval, and one interval cannot be
    # told apart from the test simply being that slow. The fixture reaches the arm with the rise
    # in place, so the refusal is the count's and not the rise's absence.
    # @intent: {"entity": "UnstableTestRunDurationStep", "action": "withhold on few runs", "behavior": "a genuine 1.0s to 4.2s rise across only two timed runs withholds :too_few_timed_runs", "layer": "unit"}
    it "withholds :too_few_timed_runs when only two timed runs exist" do
      expect(withheld_reason([1.0, 4.2])).to eq(:too_few_timed_runs)
    end

    # A window whose rows carry no duration at all is the zero case of the same arm: untimed
    # everywhere, so there is no pace to read.
    # @intent: {"entity": "UnstableTestRunDurationStep", "action": "withhold when untimed", "behavior": "a window whose every row is untimed withholds :too_few_timed_runs", "layer": "unit"}
    it "withholds :too_few_timed_runs when no run was timed" do
      expect(withheld_reason([nil, nil, nil])).to eq(:too_few_timed_runs)
    end

    # The window got faster the whole way through. Whatever the reason, there is no step UP to
    # name — and the arm fires on a falling sequence of any size.
    # @intent: {"entity": "UnstableTestRunDurationStep", "action": "withhold on no rise", "behavior": "a steadily falling 4.3 4.2 4.1 sequence withholds :no_rise", "layer": "unit"}
    it "withholds :no_rise when no consecutive pair rose" do
      expect(withheld_reason([4.3, 4.2, 4.1])).to eq(:no_rise)
    end

    # THE GAP THE TIMED SEQUENCE SKIPPED. The largest rise spans run 1 → run 3, consecutive among
    # timed runs, but run 2 sits between them in the window carrying the description untimed —
    # so the rise cannot be pinned to one observed transition and the arm refuses instead of
    # bridging. Four timed runs, so the count arm cannot be what fires.
    # @intent: {"entity": "UnstableTestRunDurationStep", "action": "withhold on untimed gap", "behavior": "an untimed run between the two ends of the largest rise withholds :untimed_between rather than bridging", "layer": "unit"}
    it "withholds :untimed_between when an untimed run sits inside the largest rise" do
      expect(withheld_reason([1.0, nil, 4.2, 4.3, 4.2])).to eq(:untimed_between)
    end

    # The complement of the arm above: an untimed run OUTSIDE the boundary pair — before or after
    # the largest rise — is a gap in the sequence, not a gap in the step, and the line still
    # offers.
    # @intent: {"entity": "UnstableTestRunDurationStep", "action": "tolerate outside gap", "behavior": "an untimed run after the largest rise leaves the step offered", "layer": "unit"}
    it "offers the step when the untimed run sits outside the boundary pair" do
      expect(described_class.for(sequence_for([1.0, 4.2, nil, 4.3, 4.2]))).to be_offered
    end

    # One commit measured twice: the same sha ingested as two runs, the pace moving between them.
    # A compare range between a commit and itself is an empty diff, so the step refuses on the
    # boundary pair's shas rather than naming one.
    # @intent: {"entity": "UnstableTestRunDurationStep", "action": "withhold on same commit", "behavior": "the largest rise whose two ends share one commit sha withholds :same_commit", "layer": "unit"}
    it "withholds :same_commit when the boundary ends are runs of one commit" do
      expect(withheld_reason([1.0, 4.2, 4.3],
                             shas: ["aabbccddee00", "aabbccddee00", sha_for(2)])).to eq(:same_commit)
    end

    # The arm is about the BOUNDARY pair only: the same commit elsewhere in the window, away from
    # the largest rise, says nothing about whether the pace stepped up between two different
    # commits, and the line still offers.
    # @intent: {"entity": "UnstableTestRunDurationStep", "action": "tolerate shared sha elsewhere", "behavior": "the same sha carried by two runs away from the boundary pair leaves the step offered", "layer": "unit"}
    it "offers the step when a shared sha sits away from the boundary pair" do
      step = described_class.for(sequence_for([1.0, 4.2, 4.3],
                                              shas: [sha_for(0), sha_for(1), sha_for(1)]))

      expect(step).to be_offered
      expect(step.from_row.commit_sha).to eq(sha_for(0))
    end
  end
end
