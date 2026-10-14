# frozen_string_literal: true

require "rails_helper"

# `SpecDirectoryWindowFileRuntimeGrowth` (SPGD-1803): which FILES of one area got slower or faster
# across the branch window's two ENDPOINTS — the file rung below `SpecDirectoryWindowRuntimeGrowth`.
RSpec.describe SpecDirectoryWindowFileRuntimeGrowth do
  let(:repository) { create_repository }

  def run_at(commit_sha, at, total: 3)
    create_test_run(repository: repository, commit_sha: commit_sha, total_specs_count: total, branch: "main",
                    created_at: at)
  end

  def observe(run, path:, line:, seconds:, layer: "unit")
    run.spec_observations.create!(
      repository: repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: seconds, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  # `count` examples in `path`, each `seconds` long (nil = untimed).
  def observe_many(run, path:, seconds:, count: 1, layer: "unit")
    count.times { |index| observe(run, path: path, line: index + 1, seconds: seconds, layer: layer) }
  end

  let(:baseline) { run_at("basewin00001", 30.days.ago) }
  let(:middle) { run_at("midwin0000001", 20.days.ago) }
  let(:anchor) { run_at("anchwin00001", 10.days.ago) }
  let(:runs) { [baseline, middle, anchor] }

  def window_growth(layer: nil) = SpecDirectoryWindowRuntimeGrowth.for(runs, branch: "main", layer: layer)

  def build(path = "spec/models", layer: nil, **)
    described_class.for(path, window_growth: window_growth(layer: layer), layer: layer, **)
  end

  def by_path(growth) = growth.rows.index_by(&:path)

  # a_spec.rb: 10s, 10s, 60s; b_spec.rb flat at 5s.
  def seed
    { baseline => 10.0, middle => 10.0, anchor => 60.0 }.each do |run, seconds|
      observe_many(run, path: "spec/models/a_spec.rb", seconds: seconds, layer: "request")
      observe_many(run, path: "spec/models/b_spec.rb", seconds: 5.0)
    end
  end

  describe "the two-endpoint comparison" do
    before { seed }

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "rank the file that crept", behavior: "a file at 10s, 10s, 60s reads baseline 10, anchor 60, change 50 and ranks first, ahead of a flat file", layer: "request" }
    it "ranks the file that got slower across the window first" do
      growth = build

      expect(growth).to be_comparable
      expect(growth.rows.map(&:path)).to eq(%w[spec/models/a_spec.rb spec/models/b_spec.rb])
      a = by_path(growth).fetch("spec/models/a_spec.rb")
      expect([a.previous_seconds, a.latest_seconds, a.change]).to eq([10.0, 60.0, 50.0])
      expect([a.baseline_label, a.anchor_label, a.change_label]).to eq(["10.00s", SpecObservation.humanized_duration(60.0), "+50.00s"])
      expect(by_path(growth).fetch("spec/models/b_spec.rb")).not_to be_moved
      expect([growth.file_count, growth.baseline_recorded_count, growth.anchor_recorded_count,
              growth.baseline_timed_count, growth.anchor_timed_count]).to eq([2, 2, 2, 2, 2])
      expect(growth).not_to be_truncated
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "read only the two ends", behavior: "rewriting the middle run's durations changes no row", layer: "request" }
    it "ignores the middle run" do
      before_rows = build.rows.map { [it.path, it.previous_seconds, it.latest_seconds] }
      middle.spec_observations.update_all(duration_seconds: 900.0)

      expect(build.rows.map { [it.path, it.previous_seconds, it.latest_seconds] }).to eq(before_rows)
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "word the movement against the baseline", behavior: "the row reading names the baseline run of this window and never the previous run", layer: "request" }
    it "words the reading against the baseline run" do
      a = by_path(build).fetch("spec/models/a_spec.rb")

      expect(a.change_reading).to eq("#{SpecObservation.humanized_duration(50.0)} slower than the baseline run of this window")
      expect(by_path(build).fetch("spec/models/b_spec.rb").change_reading)
        .to eq("took the same time as it did in the baseline run of this window")
      expect(by_path(build).fetch("spec/models/b_spec.rb").change_label).to eq("±0")
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "carry the parent's baseline", behavior: "branch, baseline and anchor runs, runs_back and window run count equal the window parent's", layer: "request" }
    it "carries the parent's baseline rather than re-deriving it" do
      parent = window_growth
      growth = described_class.for("spec/models", window_growth: parent)

      expect([growth.branch, growth.baseline_run, growth.anchor_run, growth.runs_back, growth.window_run_count])
        .to eq([parent.branch, parent.baseline_run, parent.anchor_run, parent.runs_back, parent.window_run_count])
      expect(growth.runs_back).to eq(2)
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "answer an area neither end recorded", behavior: "an unrecorded area is comparable, recorded? false, with no rows", layer: "request" }
    it "answers an area neither end recorded as comparable and not recorded" do
      growth = build("spec/nowhere")

      expect(growth).to be_comparable
      expect(growth).not_to be_recorded
      expect(growth.rows).to be_empty
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "sum to the area row", behavior: "the files' changes sum to the area's directory_runtime_window_growth change", layer: "request" }
    it "sums to the area's window change" do
      area = window_growth.rows.find { it.path == "spec/models" }

      expect(build.rows.sum(&:change)).to be_within(0.001).of(area.change)
    end
  end

  describe "a rise and fall between the two ends" do
    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "ignore a mid-window excursion", behavior: "a file that spikes in the middle run and returns reads change 0", layer: "unit" }
    it "reads change 0, two endpoints and not a series" do
      { baseline => 10.0, middle => 200.0, anchor => 10.0 }.each do |run, seconds|
        observe_many(run, path: "spec/models/a_spec.rb", seconds: seconds)
      end

      expect(by_path(build).fetch("spec/models/a_spec.rb").change).to eq(0.0)
    end
  end

  describe "three different absences" do
    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "tell new, removed and untimed files apart", behavior: "a file only at the anchor is new_file, only at the baseline removed_file, and a file one end ran but did not time is a timing_gap reading not reported rather than 0.00s", layer: "unit" }
    it "keeps new_file, removed_file and timing_gap distinguishable" do
      observe_many(baseline, path: "spec/models/old_spec.rb", seconds: 3.0)
      observe_many(anchor, path: "spec/models/new_spec.rb", seconds: 4.0)
      observe_many(baseline, path: "spec/models/quiet_spec.rb", seconds: nil)
      observe_many(anchor, path: "spec/models/quiet_spec.rb", seconds: 7.0)
      observe_many(baseline, path: "spec/models/timed_spec.rb", seconds: 1.0)
      observe_many(anchor, path: "spec/models/timed_spec.rb", seconds: 2.0)

      growth = build
      rows = by_path(growth)

      expect(rows.fetch("spec/models/new_spec.rb")).to be_new_file
      expect(rows.fetch("spec/models/new_spec.rb").change_label).to eq("New file")
      expect(rows.fetch("spec/models/new_spec.rb").change_reading).to include("a file the baseline run did not record")
      expect(rows.fetch("spec/models/old_spec.rb")).to be_removed_file
      expect(rows.fetch("spec/models/old_spec.rb").change_label).to eq("File removed")
      expect(rows.fetch("spec/models/old_spec.rb").change_reading).to eq("3.00s of examples in the baseline run and none now")
      quiet = rows.fetch("spec/models/quiet_spec.rb")
      expect(quiet).to be_timing_gap
      expect(quiet.change).to be_nil
      expect(quiet.change_label).to eq("Not timed")
      expect(quiet.baseline_label).to eq("not reported")
      expect(quiet.baseline_label).not_to include("0.00s")
      expect(growth.rows.map(&:path)).to eq(%w[spec/models/timed_spec.rb spec/models/new_spec.rb
                                               spec/models/old_spec.rb spec/models/quiet_spec.rb])
      expect(growth).to be_any_timing_gap
    end
  end

  describe "the parent's refusal" do
    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "read nothing when the parent refuses", behavior: "a window of one run carries the parent's state and issues no spec_observations read", layer: "unit" }
    it "carries the parent's state and reads nothing" do
      parent = SpecDirectoryWindowRuntimeGrowth.for([anchor], branch: "main")
      reads = queries_against("spec_observations") do
        @growth = described_class.for("spec/models", window_growth: parent)
      end

      expect(reads).to be_empty
      expect(@growth).not_to be_comparable
      expect(@growth.state).to eq(:no_earlier_run)
      expect(@growth.rows).to be_empty
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "inherit the timed states", behavior: "an untimed baseline carries the parent's baseline_untimed state, not a re-derivation from the area's totals, and reads nothing further", layer: "unit" }
    it "carries baseline_untimed from the parent without a read" do
      observe_many(baseline, path: "spec/models/a_spec.rb", seconds: nil)
      observe_many(anchor, path: "spec/models/a_spec.rb", seconds: 2.0)
      parent = SpecDirectoryWindowRuntimeGrowth.for([baseline, anchor], branch: "main")

      reads = queries_against("spec_observations") do
        @growth = described_class.for("spec/models", window_growth: parent)
      end

      expect(parent.state).to eq(:baseline_untimed)
      expect(@growth.state).to eq(:baseline_untimed)
      expect(reads).to be_empty
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "issue exactly one read when comparable", behavior: "a comparable parent costs exactly one spec_observations read", layer: "unit" }
    it "issues exactly one read when comparable" do
      seed
      parent = window_growth

      reads = queries_against("spec_observations") { described_class.for("spec/models", window_growth: parent) }

      expect(reads.length).to eq(1)
    end
  end

  describe "?layer=" do
    before do
      observe_many(baseline, path: "spec/models/a_spec.rb", seconds: 2.0, layer: "request")
      observe_many(anchor, path: "spec/models/a_spec.rb", seconds: 9.0, layer: "request")
      observe_many(baseline, path: "spec/models/u_spec.rb", seconds: 1.0)
      observe_many(anchor, path: "spec/models/u_spec.rb", seconds: 1.0)
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "narrow to a declared layer", behavior: "layer request lists only request files, echoes the layer and counts only request rows", layer: "request" }
    it "narrows the file figures and echoes the layer" do
      growth = build(layer: "request")

      expect(growth.layer).to eq("request")
      expect(growth).to be_layer
      expect(growth.rows.map(&:path)).to eq(["spec/models/a_spec.rb"])
      expect(growth.rows.first.change).to eq(7.0)
      expect([growth.baseline_recorded_count, growth.anchor_recorded_count,
              growth.baseline_timed_count, growth.anchor_timed_count]).to eq([1, 1, 1, 1])
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "read a layer present at one end only", behavior: "a layer absent from the baseline reads new_file rows rather than an unrecorded or untimed refusal", layer: "system" }
    it "reads a layer empty at the baseline as new files" do
      observe_many(anchor, path: "spec/models/s_spec.rb", seconds: 3.0, layer: "system")

      growth = build(layer: "system")

      expect(growth).to be_comparable
      expect(growth.rows.map(&:path)).to eq(["spec/models/s_spec.rb"])
      expect(growth.rows.first).to be_new_file
    end

    # @intent: { entity: "SpecDirectoryWindowFileRuntimeGrowth", action: "read a layer present at the baseline only", behavior: "a layer absent from the anchor reads removed_file rows", layer: "system" }
    it "reads a layer empty at the anchor as removed files" do
      observe_many(baseline, path: "spec/models/s_spec.rb", seconds: 3.0, layer: "system")

      growth = build(layer: "system")

      expect(growth).to be_comparable
      expect(growth.rows.map(&:path)).to eq(["spec/models/s_spec.rb"])
      expect(growth.rows.first).to be_removed_file
    end
  end
end
