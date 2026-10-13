# frozen_string_literal: true

require "rails_helper"

# `SpecDirectoryWindowRuntimeGrowth` (SPGD-1788): area TIME across the branch window's two ENDPOINTS —
# the empty cell of the area/layer x count/time x push/window grid.
RSpec.describe SpecDirectoryWindowRuntimeGrowth do
  let(:repository) { create_repository }

  def run_at(commit_sha, at, total: 3, branch: "main")
    create_test_run(repository: repository, commit_sha: commit_sha, total_specs_count: total, branch: branch,
                    created_at: at)
  end

  def observe(run, path:, line:, seconds:, layer: "unit")
    run.spec_observations.create!(
      repository: repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: seconds, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let(:baseline) { run_at("basewin00001", 30.days.ago) }
  let(:middle) { run_at("midwin0000001", 20.days.ago) }
  let(:anchor) { run_at("anchwin00001", 10.days.ago) }
  let(:runs) { [baseline, middle, anchor] }

  def by_path(growth) = growth.rows.index_by(&:path)

  # spec/models: same two examples at every run, request time 40s at the baseline, a decoy 41s in the
  # middle, 110s at the anchor. spec/jobs and spec/services are flat.
  def seed_creeping_area
    { baseline => 40.0, middle => 41.0, anchor => 110.0 }.each do |run, seconds|
      observe(run, path: "spec/models/a_spec.rb", line: 1, seconds: seconds / 2, layer: "request")
      observe(run, path: "spec/models/a_spec.rb", line: 2, seconds: seconds / 2, layer: "request")
      observe(run, path: "spec/jobs/b_spec.rb", line: 1, seconds: 5.0, layer: "unit")
      observe(run, path: "spec/services/c_spec.rb", line: 1, seconds: 2.0, layer: "unit")
    end
  end

  describe "the two-endpoint comparison" do
    before { seed_creeping_area }

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "rank the area whose time crept", behavior: "an area with the same example count at both ends and 40s then 110s of time ranks first with change 70.0 while flat areas read change 0.0", layer: "request" }
    it "ranks the area whose time crept first with the endpoint change" do
      growth = described_class.for(runs, branch: "main")

      expect(growth).to be_comparable
      expect(growth.rows.map(&:path).first).to eq("spec/models")
      models = by_path(growth).fetch("spec/models")
      expect([models.previous_seconds, models.latest_seconds, models.change]).to eq([40.0, 110.0, 70.0])
      expect(by_path(growth).fetch("spec/jobs").change).to eq(0.0)
      expect(by_path(growth).fetch("spec/services")).not_to be_moved
      expect(models.baseline_label).to eq(SpecObservation.humanized_duration(40.0))
      expect(models.anchor_label).to eq(SpecObservation.humanized_duration(110.0))
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "read only the two ends", behavior: "changing the middle run's time leaves every row identical, and the count window reads the same area as unmoved", layer: "request" }
    it "ignores the middle run entirely and shows what the count window cannot" do
      before_rows = described_class.for(runs, branch: "main").rows.map { [it.path, it.previous_seconds, it.latest_seconds] }
      middle.spec_observations.update_all(duration_seconds: 900.0)
      after_rows = described_class.for(runs, branch: "main").rows.map { [it.path, it.previous_seconds, it.latest_seconds] }

      expect(after_rows).to eq(before_rows)
      count = SpecDirectoryWindowGrowth.for(runs, branch: "main")
      expect(by_path(count).fetch("spec/models").change).to eq(0)
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "differ from the single push comparison", behavior: "the last-push runtime comparison shows the decoy middle-to-anchor delta while the window shows the end-to-end delta", layer: "request" }
    it "differs from the last-push comparison across the middle decoy" do
      push = SpecDirectoryRuntimeGrowth.for(anchor, middle)
      window = described_class.for(runs, branch: "main")

      expect(by_path(push).fetch("spec/models").change).to eq(69.0)
      expect(by_path(window).fetch("spec/models").change).to eq(70.0)
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "share the baseline walk", behavior: "baseline run, anchor run and runs_back equal those of SpecDirectoryWindowGrowth, LayerWindowGrowth and LayerWindowRuntimeGrowth for one window", layer: "request" }
    it "lands on the same baseline as the other window presenters" do
      growth = described_class.for(runs, branch: "main")
      others = [SpecDirectoryWindowGrowth.for(runs, branch: "main"), LayerWindowGrowth.for(runs, branch: "main"),
                LayerWindowRuntimeGrowth.for(runs, branch: "main")]

      others.each do |other|
        expect([other.baseline_run, other.anchor_run, other.runs_back])
          .to eq([growth.baseline_run, growth.anchor_run, growth.runs_back])
      end
      expect(growth.runs_back).to eq(2)
      expect(growth.covered_run_count).to eq(3)
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "carry the walk when it steps over runs", behavior: "an unmeasured oldest run is skipped, the baseline is the middle run and shortened is true", layer: "request" }
    it "follows the shared walk when it steps over an unmeasured run" do
      baseline.update_columns(total_specs_count: 0)
      growth = described_class.for(runs, branch: "main")

      expect(growth.baseline_run).to eq(middle)
      expect(growth.runs_back).to eq(1)
      expect(growth).to be_shortened
      expect(growth.skipped_unmeasured_count).to eq(1)
      expect(by_path(growth).fetch("spec/models").change).to eq(69.0)
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "cap the listed areas", behavior: "a limit below the area count lists that many rows and reports truncated with the full directory count", layer: "request" }
    it "discloses the cap" do
      growth = described_class.for(runs, branch: "main", limit: 2)

      expect(growth.rows.size).to eq(2)
      expect(growth.directory_count).to eq(3)
      expect(growth).to be_truncated
      expect(growth.rows.first.path).to eq("spec/models")
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "bound its reads", behavior: "a comparable window issues exactly one spec_observations read and the unasked SQL has no layer predicate", layer: "request" }
    it "issues exactly one observation read when comparable" do
      statements = queries_against("spec_observations") { described_class.for(runs, branch: "main") }

      expect(statements.size).to eq(1)
      expect(statements.first).not_to include("intent_layer")
    end
  end

  describe "a layer ask" do
    before do
      seed_creeping_area
      observe(anchor, path: "spec/jobs/b_spec.rb", line: 2, seconds: 8.0, layer: "request")
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "narrow to a layer", behavior: "with request asked the rows are the request layer's own and the area changes sum to LayerWindowRuntimeGrowth's request change when every area is timed at both ends", layer: "request" }
    it "sums to the layer window change when every area is timed at both ends" do
      growth = described_class.for(runs, branch: "main", layer: "request")

      expect(growth).to be_comparable
      expect(growth.layer).to eq("request")
      expect(growth).to be_layer
      expect(growth.rows.map(&:path)).to eq(%w[spec/models spec/jobs])
      expect(by_path(growth).fetch("spec/jobs")).to be_new_area
      # Documented exception: a new area has no baseline time, so the sum covers only areas timed at BOTH
      # ends; add the new area's own anchor time to recover the layer's total.
      both_timed = growth.rows.select(&:comparable?).sum(&:change)
      layer_change = LayerWindowRuntimeGrowth.for(runs, branch: "main").rows.fetch(:request).change
      expect(both_timed + by_path(growth).fetch("spec/jobs").latest_seconds).to be_within(0.001).of(layer_change)
      expect([growth.directory_count, growth.baseline_recorded_count, growth.anchor_recorded_count])
        .to eq([2, 2, 3])
      expect([growth.baseline_timed_count, growth.anchor_timed_count]).to eq([2, 3])
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "equal the layer change when all areas are timed", behavior: "with every request area present and timed at both ends the area changes sum exactly to the layer's request change", layer: "request" }
    it "sums exactly when every area exists at both ends" do
      observe(baseline, path: "spec/jobs/b_spec.rb", line: 2, seconds: 3.0, layer: "request")
      growth = described_class.for(runs, branch: "main", layer: "request")

      expect(growth.rows).to all(be_comparable)
      expect(growth.rows.sum(&:change))
        .to be_within(0.001).of(LayerWindowRuntimeGrowth.for(runs, branch: "main").rows.fetch(:request).change)
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "compare a layer absent from the baseline", behavior: "a layer only the anchor has is comparable with every area new, not baseline_unrecorded", layer: "system" }
    it "is comparable with every area new for a layer only the anchor has" do
      observe(anchor, path: "spec/jobs/sys_spec.rb", line: 1, seconds: 4.0, layer: "system")
      growth = described_class.for(runs, branch: "main", layer: "system")

      expect(growth.state).to eq(:comparable)
      expect(growth.rows.map { [it.path, it.new_area?] }).to eq([["spec/jobs", true]])
      expect(growth.baseline_recorded_count).to eq(0)
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "compare a layer absent from the anchor", behavior: "a layer only the baseline has is comparable with every area removed", layer: "integration" }
    it "is comparable with every area removed for a layer only the baseline has" do
      observe(baseline, path: "spec/legacy/c_spec.rb", line: 1, seconds: 4.0, layer: "integration")
      growth = described_class.for(runs, branch: "main", layer: "integration")

      expect(growth.state).to eq(:comparable)
      expect(growth.rows.map { [it.path, it.removed_area?] }).to eq([["spec/legacy", true]])
      expect(growth.anchor_recorded_count).to eq(0)
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "answer a layer absent at both ends", behavior: "comparable and layer_empty with no rows and directory_count 0, never neither_recorded or neither_timed", layer: "system" }
    it "is comparable and layer-empty for a layer neither end has" do
      growth = described_class.for(runs, branch: "main", layer: "system")

      expect(growth.state).to eq(:comparable)
      expect(growth).to be_layer_empty
      expect([growth.rows, growth.directory_count]).to eq([[], 0])
      expect(described_class.for(runs, branch: "main")).not_to be_layer_empty
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "refuse a layer present but untimed on one end", behavior: "a layer whose baseline examples were all untimed reads baseline_untimed, though the layer-empty anchor-less case stays comparable", layer: "request" }
    it "reads untimed only on an end that has the layer" do
      baseline.spec_observations.where(intent_layer: "request").update_all(duration_seconds: nil)

      expect(described_class.for(runs, branch: "main", layer: "request").state).to eq(:baseline_untimed)
      # The unit layer is timed at both ends, so the same window still compares for it.
      expect(described_class.for(runs, branch: "main", layer: "unit").state).to eq(:comparable)
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "carry the layer into walk states", behavior: "a one-run window reads no_earlier_run with the layer carried and issues no spec_observations read", layer: "request" }
    it "carries the layer into walk-decided states and reads nothing" do
      statements = queries_against("spec_observations") do
        growth = described_class.for([anchor], branch: "main", layer: "request")
        expect(growth.state).to eq(:no_earlier_run)
        expect(growth.layer).to eq("request")
      end

      expect(statements).to be_empty
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "issue one grouped read under a layer", behavior: "a comparable layered window issues exactly one spec_observations read carrying the layer predicate once the endpoint run aggregates are primed", layer: "request" }
    it "issues exactly one area read under a layer" do
      [baseline, anchor].each { |run| [run.intent_readings, run.layer_counts] }
      statements = queries_against("spec_observations") { described_class.for(runs, branch: "main", layer: "request") }

      expect(statements.size).to eq(1)
      expect(statements.first).to include("intent_layer")
    end
  end

  describe "the absences" do
    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "never difference an untimed area", behavior: "an area timed at one end only has change nil, is a timing gap and sorts after every timed area", layer: "request" }
    it "gives an area untimed at one end change nil and sorts it last" do
      seed_creeping_area
      baseline.spec_observations.where("spec_file_path LIKE 'spec/jobs%'").update_all(duration_seconds: nil)
      growth = described_class.for(runs, branch: "main")

      jobs = by_path(growth).fetch("spec/jobs")
      expect(jobs.change).to be_nil
      expect(jobs).to be_timing_gap
      expect(jobs.change_label).to eq("Not timed")
      expect(growth.rows.last).to eq(jobs)
      expect(growth).to be_any_timing_gap
      expect(growth.rows.first.path).to eq("spec/models")
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "word rows by the window", behavior: "the change reading names the baseline run of this window and never the previous run on this branch", layer: "request" }
    it "words the aria reading against the window's baseline" do
      seed_creeping_area
      reading = by_path(described_class.for(runs, branch: "main")).fetch("spec/models").change_reading

      expect(reading).to include("slower than the baseline run of this window")
      expect(reading).not_to include("previous run")
    end

    def states_for(window_runs, **) = described_class.for(window_runs, branch: "main", **).state

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "name every walk-decided state without reading", behavior: "anchor_unmeasured, no_earlier_run, no_measured_baseline and no_comparable_composition are decided in memory with no spec_observations read", layer: "request" }
    it "decides the four walk states with no observation read" do
      unmeasured_anchor = run_at("zerowin00001", 5.days.ago, total: 0)
      zero_baseline = run_at("zerobase0001", 31.days.ago, total: 0)
      mismatched = [baseline, anchor]
      allow(anchor).to receive(:assembled_like?).and_return(false)

      reads = queries_against("spec_observations") do
        expect(states_for([baseline, unmeasured_anchor])).to eq(:anchor_unmeasured)
        expect(states_for([anchor])).to eq(:no_earlier_run)
        expect(states_for([zero_baseline, anchor])).to eq(:no_measured_baseline)
        expect(states_for(mismatched)).to eq(:no_comparable_composition)
      end

      expect(reads).to be_empty
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "name the row-derived absences", behavior: "no rows at either end, one end or the other read neither_recorded, baseline_unrecorded and anchor_unrecorded, and untimed rows read the three untimed states", layer: "request" }
    it "names the recorded and timed absences" do
      other = run_at("otherwin00001", 5.days.ago)
      observe(baseline, path: "spec/models/a_spec.rb", line: 1, seconds: 1.0)
      observe(other, path: "spec/models/a_spec.rb", line: 1, seconds: 1.0)

      expect(states_for([baseline, anchor])).to eq(:anchor_unrecorded)
      expect(states_for([anchor, other])).to eq(:baseline_unrecorded)
      expect(states_for([anchor, run_at("emptywin00001", 4.days.ago)])).to eq(:neither_recorded)

      untimed = run_at("untimedwin001", 3.days.ago)
      observe(untimed, path: "spec/models/a_spec.rb", line: 1, seconds: nil)
      expect(states_for([baseline, untimed])).to eq(:anchor_untimed)
      expect(states_for([untimed, other])).to eq(:baseline_untimed)
      untimed_two = run_at("untimedtwo001", 2.days.ago)
      observe(untimed_two, path: "spec/models/a_spec.rb", line: 1, seconds: nil)
      expect(states_for([untimed, untimed_two])).to eq(:neither_timed)
    end

    # @intent: { entity: "SpecDirectoryWindowRuntimeGrowth", action: "keep the recorded states at run grain under a layer", behavior: "an end with no per-example rows keeps its unrecorded state when a layer is asked", layer: "request" }
    it "keeps the unrecorded states under a layer ask" do
      seed_creeping_area
      bare = run_at("barewin00001", 31.days.ago)
      bare_anchor = run_at("bareanch0001", 5.days.ago)

      expect(states_for([bare, middle, anchor], layer: "request")).to eq(:baseline_unrecorded)
      expect(states_for([baseline, middle, bare_anchor], layer: "request")).to eq(:anchor_unrecorded)
      expect(states_for([bare, bare_anchor], layer: "request")).to eq(:neither_recorded)
    end
  end
end
