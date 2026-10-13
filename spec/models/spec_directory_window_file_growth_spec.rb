# frozen_string_literal: true

require "rails_helper"

# `SpecDirectoryWindowFileGrowth` (SPGD-1794): which FILES of one area moved across the branch
# window's two ENDPOINTS — the file rung below `SpecDirectoryWindowGrowth`.
RSpec.describe SpecDirectoryWindowFileGrowth do
  let(:repository) { create_repository }

  def run_at(commit_sha, at, total: 3)
    create_test_run(repository: repository, commit_sha: commit_sha, total_specs_count: total, branch: "main",
                    created_at: at)
  end

  def observe(run, path:, line:, layer: "unit")
    run.spec_observations.create!(
      repository: repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: 1.0, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  def observe_many(run, path:, count:, layer: "unit")
    count.times { |index| observe(run, path: path, line: index + 1, layer: layer) }
  end

  let(:baseline) { run_at("basewin00001", 30.days.ago) }
  let(:middle) { run_at("midwin0000001", 20.days.ago) }
  let(:anchor) { run_at("anchwin00001", 10.days.ago) }
  let(:runs) { [baseline, middle, anchor] }

  def window_growth(layer: nil) = SpecDirectoryWindowGrowth.for(runs, branch: "main", layer: layer)

  def build(path = "spec/models", layer: nil, **)
    described_class.for(path, window_growth: window_growth(layer: layer), layer: layer, **)
  end

  def by_path(growth) = growth.rows.index_by(&:path)

  # a_spec.rb: 10 at the baseline, 10 in the middle, 20 at the anchor; b_spec.rb flat at 5.
  def seed
    { baseline => 10, middle => 10, anchor => 20 }.each do |run, count|
      observe_many(run, path: "spec/models/a_spec.rb", count: count, layer: "request")
      observe_many(run, path: "spec/models/b_spec.rb", count: 5)
    end
  end

  describe "the two-endpoint comparison" do
    before { seed }

    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "rank the file that grew across the window", behavior: "a file at 10, 10, 20 examples reads baseline 10, anchor 20, change 10 and ranks first, with a flat file at change 0", layer: "request" }
    it "ranks the file that grew across the window first" do
      growth = build

      expect(growth).to be_comparable
      expect(growth.rows.map(&:path)).to eq(%w[spec/models/a_spec.rb spec/models/b_spec.rb])
      a = by_path(growth).fetch("spec/models/a_spec.rb")
      expect([a.previous_count, a.latest_count, a.change]).to eq([10, 20, 10])
      expect([a.baseline_count_label, a.anchor_count_label]).to eq(%w[10 20])
      expect(by_path(growth).fetch("spec/models/b_spec.rb")).not_to be_moved
      expect([growth.file_count, growth.baseline_recorded_count, growth.anchor_recorded_count]).to eq([2, 15, 25])
      expect(growth).not_to be_truncated
    end

    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "read only the two ends", behavior: "rewriting the middle run changes no row", layer: "request" }
    it "ignores the middle run" do
      before_rows = build.rows.map { [it.path, it.previous_count, it.latest_count] }
      middle.spec_observations.where(spec_file_path: "spec/models/a_spec.rb").destroy_all
      observe_many(middle, path: "spec/models/a_spec.rb", count: 99)

      expect(build.rows.map { [it.path, it.previous_count, it.latest_count] }).to eq(before_rows)
    end

    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "word the movement against the baseline", behavior: "the row reading names the baseline run of this window and never the previous run", layer: "request" }
    it "words the reading against the baseline run" do
      reading = by_path(build).fetch("spec/models/a_spec.rb").change_reading

      expect(reading).to eq("10 examples more than the baseline run of this window")
      expect(by_path(build).fetch("spec/models/b_spec.rb").change_reading).to include("baseline run of this window")
      expect(reading).not_to include("previous run")
    end

    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "carry the parent's baseline", behavior: "branch, baseline and anchor runs, runs_back and window run count equal the window parent's", layer: "request" }
    it "carries the parent's baseline rather than re-deriving it" do
      parent = window_growth
      growth = described_class.for("spec/models", window_growth: parent)

      expect([growth.branch, growth.baseline_run, growth.anchor_run, growth.runs_back, growth.window_run_count])
        .to eq([parent.branch, parent.baseline_run, parent.anchor_run, parent.runs_back, parent.window_run_count])
      expect(growth.runs_back).to eq(2)
    end

    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "answer an area neither end recorded", behavior: "an unrecorded area is comparable, recorded? false, with no rows", layer: "request" }
    it "answers an area neither end recorded as comparable and not recorded" do
      growth = build("spec/nowhere")

      expect(growth).to be_comparable
      expect(growth).not_to be_recorded
      expect(growth.rows).to be_empty
    end
  end

  describe "files on one side only" do
    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "name a file present at one end only", behavior: "a file only at the anchor is new_file and a file only at the baseline is removed_file, neither read as ±0", layer: "unit" }
    it "reads new_file and removed_file, never ±0" do
      observe_many(baseline, path: "spec/models/old_spec.rb", count: 3)
      observe_many(anchor, path: "spec/models/new_spec.rb", count: 4)
      observe_many(baseline, path: "spec/models/keep_spec.rb", count: 1)
      observe_many(anchor, path: "spec/models/keep_spec.rb", count: 1)
      observe_many(middle, path: "spec/models/keep_spec.rb", count: 1)

      rows = by_path(build)

      expect(rows.fetch("spec/models/new_spec.rb")).to be_new_file
      expect(rows.fetch("spec/models/new_spec.rb").change_label).to eq("New file")
      expect(rows.fetch("spec/models/new_spec.rb").change_reading).to include("a file the baseline run did not record")
      expect(rows.fetch("spec/models/old_spec.rb")).to be_removed_file
      expect(rows.fetch("spec/models/old_spec.rb").change_reading).to eq("3 examples in the baseline run and none now")
    end
  end

  describe "the parent's refusal" do
    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "read nothing when the parent refuses", behavior: "a window of one run carries the parent's state and issues no spec_observations read", layer: "unit" }
    it "carries the parent's state and reads nothing" do
      parent = SpecDirectoryWindowGrowth.for([anchor], branch: "main")
      reads = queries_against("spec_observations") do
        @growth = described_class.for("spec/models", window_growth: parent)
      end

      expect(reads).to be_empty
      expect(@growth).not_to be_comparable
      expect(@growth.state).to eq(parent.state)
      expect(@growth.state).to eq(:no_earlier_run)
      expect(@growth.rows).to be_empty
    end

    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "issue exactly one read when comparable", behavior: "a comparable parent costs exactly one spec_observations read", layer: "unit" }
    it "issues exactly one read when comparable" do
      seed
      parent = window_growth

      reads = queries_against("spec_observations") { described_class.for("spec/models", window_growth: parent) }

      expect(reads.length).to eq(1)
    end
  end

  describe "?layer=" do
    before do
      observe_many(baseline, path: "spec/models/a_spec.rb", count: 2, layer: "request")
      observe_many(anchor, path: "spec/models/a_spec.rb", count: 5, layer: "request")
      observe(baseline, path: "spec/models/u_spec.rb", line: 1)
      observe(anchor, path: "spec/models/u_spec.rb", line: 1)
    end

    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "narrow to a declared layer", behavior: "layer request lists only request examples per file, echoes the layer, and counts only request rows", layer: "request" }
    it "narrows the file figures and echoes the layer" do
      growth = build(layer: "request")

      expect(growth.layer).to eq("request")
      expect(growth).to be_layer
      expect(growth.rows.map(&:path)).to eq(["spec/models/a_spec.rb"])
      expect([growth.rows.first.previous_count, growth.rows.first.latest_count]).to eq([2, 5])
      expect([growth.baseline_recorded_count, growth.anchor_recorded_count]).to eq([2, 5])
    end

    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "read a layer present at one end only", behavior: "a layer absent from the baseline reads new_file rows rather than an unrecorded refusal", layer: "system" }
    it "reads a layer empty at the baseline as new files" do
      observe(anchor, path: "spec/models/s_spec.rb", line: 1, layer: "system")

      growth = build(layer: "system")

      expect(growth).to be_comparable
      expect(growth.rows.map(&:path)).to eq(["spec/models/s_spec.rb"])
      expect(growth.rows.first).to be_new_file
    end

    # @intent: { entity: "SpecDirectoryWindowFileGrowth", action: "inherit the layer-recorded states", behavior: "a layered window whose baseline recorded no examples carries the parent's baseline_unrecorded state and reads nothing", layer: "request" }
    it "carries the parent's layer-recorded refusal without a read" do
      Rails.application.executor.wrap { SpecObservation.where(test_run_id: baseline.id).delete_all }
      baseline.reload
      parent = window_growth(layer: "request")
      reads = queries_against("spec_observations") do
        @growth = described_class.for("spec/models", window_growth: parent, layer: "request")
      end

      expect(parent.state).to eq(:baseline_unrecorded)
      expect(@growth.state).to eq(:baseline_unrecorded)
      expect(@growth.layer).to eq("request")
      expect(reads).to be_empty
    end
  end
end
