# frozen_string_literal: true

require "rails_helper"

# The presenter that mechanizes the "This test, run by run" panel's reading rule — the last run
# that passed and the first that failed, or the specific arm of the rule that refuses this window.
#
# Bare structs stand in for runs and observations here, on the precedent `RunWindow`'s own spec
# sets: what is under test is which rows the walk picks and which arm fires, and none of that reads
# anything a real record carries beyond `commit_sha`, `test_run_id` and `outcome`. The sequences are
# built through `UnstableTestRuns` itself rather than around it, so the rows under test are the
# `Row` structs the panel actually hands over — the fixture exercises the real pairing of run to
# observation, not a parallel shape that agrees today for no structural reason.
#
# The one behavioural fact every example below leans on, stated here rather than re-derived per
# example: the rows are OLDEST RUN FIRST, because the web panel's window is (`Repository#
# suite_size_trajectory` — the direction the "Suite growth" chart is plotted in and the scope
# sentence on the page states). A fixture in the other orientation would test a window this
# presenter is never rendered beside.
RSpec.describe UnstableTestRunOnset do
  Run = Struct.new(:id, :commit_sha, :branch, :created_at, keyword_init: true)
  Observation = Struct.new(:test_run_id, :outcome, :duration_seconds, :spec_file_path,
                           :line_number, :unstable_test_recorded_count,
                           :unstable_test_reported_outcome_count, keyword_init: true)

  def sha_for(index) = "#{format("%02d", index)}c0ffee0000"

  # One sequence from outcomes per run, oldest run first. Each entry is one run: a plain value is
  # that run's single row outcome, an array is several rows in one run (the table-driven shape),
  # and nil is a row that recorded the test and reported no outcome — all three are states the real
  # read produces. The window counts are stamped on every observation the way the real read stamps
  # them, so the cap check reads the same operands off whichever row it asks.
  def sequence_for(outcomes_per_run, shas: nil, recorded_count: nil)
    shas ||= outcomes_per_run.each_index.map { |index| sha_for(index) }
    runs = outcomes_per_run.each_index.map do |index|
      Run.new(id: index + 1, commit_sha: shas[index], branch: "main", created_at: Time.current)
    end
    total = outcomes_per_run.sum { |per_run| per_run.is_a?(Array) ? per_run.size : 1 }
    reported = outcomes_per_run.flatten.count(&:itself)

    observations = runs.each_with_index.flat_map do |run, index|
      outcomes = outcomes_per_run[index].is_a?(Array) ? outcomes_per_run[index] : [outcomes_per_run[index]]
      outcomes.map do |outcome|
        Observation.new(test_run_id: run.id, outcome: outcome, duration_seconds: 0.1,
                        spec_file_path: "spec/models/invoice_spec.rb", line_number: 1,
                        unstable_test_recorded_count: recorded_count || total,
                        unstable_test_reported_outcome_count: reported)
      end
    end

    UnstableTestRuns.new(name: "Invoice finalize locks the line items", runs: runs,
                         observations: observations)
  end

  # THE ANSWER IT EXISTS FOR. Twenty-six passes then four failures at the end of the window — the
  # textbook regression — names run 26 as the last pass and run 27 as the first fail, and names
  # them by their own commits.
  # @intent: {"entity": "UnstableTestRunOnset", "action": "name the onset", "behavior": "26 passes then 4 failures returns an onset whose last pass is run 26 and first fail is run 27, each named by its own run's commit", "layer": "unit"}
  it "names the last passing run and the first failing run of a textbook regression" do
    onset = described_class.for(sequence_for(%w[passed] * 26 + %w[failed] * 4))

    expect(onset).to be_onset
    expect(onset.last_pass_row.commit_sha).to eq(sha_for(25))
    expect(onset.first_fail_row.commit_sha).to eq(sha_for(26))
    expect(onset).not_to be_withheld
  end

  # The boundary pair is the pass immediately BEFORE the block and the fail that OPENS it — not
  # the window's newest failing run. The distinction is the whole point: the newest failure of a
  # four-failure regression is run 30, and ranging from run 29 would name the wrong candidate set.
  # @intent: {"entity": "UnstableTestRunOnset", "action": "pin the boundary pair", "behavior": "2 passes then 2 failures returns the middle pair — the second pass and the first failure — not either end run", "layer": "unit"}
  it "picks the pass that closes the passing stretch and the failure that opens the failing one" do
    onset = described_class.for(sequence_for(%w[passed passed failed failed]))

    expect(onset.last_pass_row.commit_sha).to eq(sha_for(1))
    expect(onset.first_fail_row.commit_sha).to eq(sha_for(2))
  end

  # Silence BEFORE the boundary is not the boundary's problem: a run that recorded nothing earlier
  # in the window says nothing about the flip, so it neither breaks the block nor unobserves the
  # pair. (A silent run AT the boundary is a different case, refused below.)
  # @intent: {"entity": "UnstableTestRunOnset", "action": "tolerate earlier silence", "behavior": "a silent run before the passing run still yields an onset between the pass and the failure", "layer": "unit"}
  it "offers the onset when a run before the boundary reported nothing" do
    onset = described_class.for(sequence_for([nil, "passed", "failed"]))

    expect(onset).to be_onset
    expect(onset.last_pass_row.commit_sha).to eq(sha_for(1))
    expect(onset.first_fail_row.commit_sha).to eq(sha_for(2))
  end

  # EVERY reported row failed — the window opens inside the regression. Offered as its own answer
  # rather than withheld: "predates this window" tells the reader where to look next, which is more
  # than any withhold reason would.
  # @intent: {"entity": "UnstableTestRunOnset", "action": "answer predates window", "behavior": "a window whose every reported row failed returns failing_since_window_start with no onset and no withhold", "layer": "unit"}
  it "answers failing_since_window_start when every reported row failed" do
    onset = described_class.for(sequence_for(%w[failed failed failed]))

    expect(onset).to be_failing_since_window_start
    expect(onset).not_to be_onset
    expect(onset).not_to be_withheld
  end

  describe "each withhold arm" do
    def withheld_reason(outcomes_per_run, **opts)
      described_class.for(sequence_for(outcomes_per_run, **opts)).tap do |onset|
        expect(onset).to be_withheld
      end.reason
    end

    # The cap took the newest rows off this window, so the trailing end an onset is read from is
    # not on the page — the same predicate the panel's cap alert states, refusing for the same
    # reason so the line and the alert cannot disagree.
    # @intent: {"entity": "UnstableTestRunOnset", "action": "withhold when capped", "behavior": "a sequence whose recorded count exceeds its listed rows withholds :capped", "layer": "unit"}
    it "withholds :capped when the cap took rows off the list" do
      expect(withheld_reason(%w[passed failed], recorded_count: 202)).to eq(:capped)
    end

    # A run whose own rows disagree has no single outcome, and every run-grain reading below is
    # undefined until it has been refused.
    # @intent: {"entity": "UnstableTestRunOnset", "action": "withhold on mixed run", "behavior": "a run carrying both a passed and a failed row withholds :mixed_run even when the rest of the window is a clean regression", "layer": "unit"}
    it "withholds :mixed_run when one run's rows disagree" do
      expect(withheld_reason([%w[passed failed], "failed", "failed"])).to eq(:mixed_run)
    end

    # DIRECT FLAKE EVIDENCE: the same code both passed and failed this test somewhere in the window.
    # Said instead of offered, wherever in the window it sits.
    # @intent: {"entity": "UnstableTestRunOnset", "action": "withhold on same commit", "behavior": "one commit sha appearing with both outcomes in different runs withholds :same_commit", "layer": "unit"}
    it "withholds :same_commit when one sha both passed and failed the test" do
      expect(withheld_reason(%w[passed failed], shas: %w[aabbccddee00 aabbccddee00]))
        .to eq(:same_commit)
    end

    # @intent: {"entity": "UnstableTestRunOnset", "action": "withhold when silent", "behavior": "a window where no row reported an outcome withholds :nothing_reported", "layer": "unit"}
    it "withholds :nothing_reported when no row reported an outcome" do
      expect(withheld_reason([nil, nil])).to eq(:nothing_reported)
    end

    # A window that ends in a pass has no trailing failing block for an onset to close, whatever
    # happened earlier in it.
    # @intent: {"entity": "UnstableTestRunOnset", "action": "withhold when newest passed", "behavior": "a window whose newest reported row passed withholds :newest_not_failed", "layer": "unit"}
    it "withholds :newest_not_failed when the window ends in a pass" do
      expect(withheld_reason(%w[failed passed])).to eq(:newest_not_failed)
    end

    # THE FLAKINESS SHAPE. The trailing block and its boundary are perfectly clean here, and the
    # onset is still refused: a failure older than the last pass means the failures are scattered,
    # and the newest failure of a scattered window is the latest one, not the first one.
    # @intent: {"entity": "UnstableTestRunOnset", "action": "withhold on scattered failures", "behavior": "a failure older than the last passing run withholds :scattered even though the trailing block is clean", "layer": "unit"}
    it "withholds :scattered when a failure sits outside the trailing block" do
      expect(withheld_reason(%w[failed passed failed])).to eq(:scattered)
    end

    # An unobserved run AT the boundary — between the pass and the failure, or after the last
    # observed failure — unobserves the flip or its trailing-ness. Both directions refuse through
    # the same arm.
    # @intent: {"entity": "UnstableTestRunOnset", "action": "withhold on dirty boundary", "behavior": "a silent run between the pass and the failure withholds :ambiguous_boundary, as does a silent run after the last failure", "layer": "unit"}
    it "withholds :ambiguous_boundary when a run at the boundary reported nothing" do
      expect(withheld_reason(["passed", nil, "failed"])).to eq(:ambiguous_boundary)
      expect(withheld_reason(["passed", "failed", nil])).to eq(:ambiguous_boundary)
    end

    # The stricter form of the same arm: a boundary run carrying a row that reported nothing leaves
    # a silent row sitting exactly between the pass and the failure.
    # @intent: {"entity": "UnstableTestRunOnset", "action": "withhold on boundary rows", "behavior": "a passing run that also carries a silent row withholds :ambiguous_boundary, as does a first failing run that does", "layer": "unit"}
    it "withholds :ambiguous_boundary when a boundary run carries a row that did not agree" do
      expect(withheld_reason([%w[passed nil].map { |word| word == "nil" ? nil : word }, "failed"]))
        .to eq(:ambiguous_boundary)
      expect(withheld_reason(["passed", ["nil", "failed"].map { |word| word == "nil" ? nil : word }]))
        .to eq(:ambiguous_boundary)
    end
  end
end
