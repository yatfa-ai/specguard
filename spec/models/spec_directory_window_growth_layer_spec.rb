# frozen_string_literal: true

require "rails_helper"

# `layer:` on `SpecDirectoryWindowGrowth` (SPGD-1782): the state derivation under a declared-layer ask.
RSpec.describe SpecDirectoryWindowGrowth do
  let(:repository) { create_repository }

  def run_at(commit_sha, at, total: 0)
    create_test_run(repository: repository, commit_sha: commit_sha, total_specs_count: total, branch: "main",
                    created_at: at)
  end

  def observe(run, path:, line:, layer:)
    run.spec_observations.create!(
      repository: repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: 1.0, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let(:baseline) { run_at("basewin00001", 30.days.ago, total: 3) }
  let(:middle) { run_at("midwin0000001", 20.days.ago, total: 3) }
  let(:anchor) { run_at("anchwin00001", 10.days.ago, total: 4) }
  let(:runs) { [baseline, middle, anchor] }

  before do
    observe(baseline, path: "spec/models/a_spec.rb", line: 1, layer: "unit")
    observe(baseline, path: "spec/models/a_spec.rb", line: 2, layer: "request")
    observe(middle, path: "spec/models/a_spec.rb", line: 1, layer: "unit")
    observe(anchor, path: "spec/models/a_spec.rb", line: 1, layer: "unit")
    observe(anchor, path: "spec/models/a_spec.rb", line: 2, layer: "request")
    observe(anchor, path: "spec/models/a_spec.rb", line: 3, layer: "request")
    observe(anchor, path: "spec/jobs/b_spec.rb", line: 1, layer: "request")
  end

  # @intent: { entity: "SpecDirectoryWindowGrowth", action: "narrow the endpoint comparison to a layer", behavior: "with a layer asked the rows, directory count and recorded counts are that layer's own, and the layer is carried on the presenter", layer: "request" }
  it "counts only the layer's examples at the two endpoints" do
    growth = described_class.for(runs, branch: "main", layer: "request")

    expect(growth).to be_comparable
    expect(growth.layer).to eq("request")
    expect(growth).to be_layer
    expect(growth.rows.to_h { [it.path, [it.previous_count, it.latest_count]] })
      .to eq("spec/models" => [1, 2], "spec/jobs" => [0, 1])
    expect([growth.directory_count, growth.baseline_recorded_count, growth.anchor_recorded_count]).to eq([2, 1, 3])
    expect(growth.rows.sum(&:change)).to eq(LayerWindowGrowth.for(runs, branch: "main").rows.fetch(:request).change)
  end

  # @intent: { entity: "SpecDirectoryWindowGrowth", action: "stay un-narrowed without a layer", behavior: "no layer leaves layer nil and every area counting all layers", layer: "request" }
  it "is un-narrowed without a layer" do
    growth = described_class.for(runs, branch: "main")

    expect(growth.layer).to be_nil
    expect(growth).not_to be_layer
    expect(growth).not_to be_layer_empty
    expect(growth.rows.to_h { [it.path, [it.previous_count, it.latest_count]] })
      .to eq("spec/models" => [2, 3], "spec/jobs" => [0, 1])
  end

  # @intent: { entity: "SpecDirectoryWindowGrowth", action: "compare a layer absent from the baseline", behavior: "a layer the baseline had none of is comparable with every area new, not baseline_unrecorded", layer: "system" }
  it "is comparable with new areas for a layer only the anchor has" do
    observe(anchor, path: "spec/jobs/sys_spec.rb", line: 1, layer: "system")
    growth = described_class.for(runs, branch: "main", layer: "system")

    expect(growth.state).to eq(:comparable)
    expect(growth.rows.map { [it.path, it.new_area?] }).to eq([["spec/jobs", true]])
    expect(growth.baseline_recorded_count).to eq(0)
  end

  # @intent: { entity: "SpecDirectoryWindowGrowth", action: "compare a layer absent from the anchor", behavior: "a layer the anchor has none of is comparable with every area removed", layer: "request" }
  it "is comparable with removed areas for a layer only the baseline has" do
    observe(baseline, path: "spec/legacy/c_spec.rb", line: 1, layer: "integration")
    growth = described_class.for(runs, branch: "main", layer: "integration")

    expect(growth.state).to eq(:comparable)
    expect(growth.rows.map { [it.path, it.removed_area?] }).to eq([["spec/legacy", true]])
    expect(growth.anchor_recorded_count).to eq(0)
  end

  # @intent: { entity: "SpecDirectoryWindowGrowth", action: "answer a layer absent at both ends", behavior: "comparable and layer_empty with zero rows and directory_count 0, never neither_recorded", layer: "system" }
  it "is comparable and layer-empty for a layer neither end has" do
    growth = described_class.for(runs, branch: "main", layer: "system")

    expect(growth.state).to eq(:comparable)
    expect(growth).to be_layer_empty
    expect([growth.rows, growth.directory_count]).to eq([[], 0])
    expect(described_class.for(runs, branch: "main")).not_to be_layer_empty
  end

  # @intent: { entity: "SpecDirectoryWindowGrowth", action: "keep the unrecorded states at run grain", behavior: "an end with no per-example rows keeps its unrecorded state when a layer is asked", layer: "request" }
  it "keeps the unrecorded states under a layer ask" do
    bare = run_at("barewin00001", 31.days.ago, total: 3)
    expect(described_class.for([bare, middle, anchor], branch: "main", layer: "request").state)
      .to eq(:baseline_unrecorded)
    bare_anchor = run_at("bareanch0001", 5.days.ago, total: 3)
    expect(described_class.for([baseline, middle, bare_anchor], branch: "main", layer: "request").state)
      .to eq(:anchor_unrecorded)
    expect(described_class.for([bare, bare_anchor], branch: "main", layer: "request").state).to eq(:neither_recorded)
  end

  # @intent: { entity: "SpecDirectoryWindowGrowth", action: "carry the layer into walk-decided states", behavior: "a one-run window reads no_earlier_run with the layer carried and no spec_observations read", layer: "request" }
  it "carries the layer into walk-decided states and issues no read" do
    statements = queries_against("spec_observations") do
      growth = described_class.for([anchor], branch: "main", layer: "request")
      expect(growth.state).to eq(:no_earlier_run)
      expect(growth.layer).to eq("request")
    end

    expect(statements).to be_empty
  end

  # @intent: { entity: "SpecDirectoryWindowGrowth", action: "keep the unasked SQL unchanged", behavior: "the presenter issues the same spec_observations statements for no layer and layer nil, with no layer predicate, and one grouped read under a layer", layer: "request" }
  it "issues byte-identical SQL for a nil layer and one grouped read for a layer" do
    # The two endpoints' memoized run aggregates (`intent_readings`/`layer_counts`) are read by the page
    # anyway, for the Overview and `LayerWindowGrowth`; primed here so what is counted is the area read.
    [baseline, anchor].each(&:intent_readings)
    plain = queries_against("spec_observations") { described_class.for(runs, branch: "main") }
    nil_layer = queries_against("spec_observations") { described_class.for(runs, branch: "main", layer: nil) }
    asked = queries_against("spec_observations") { described_class.for(runs, branch: "main", layer: "request") }

    expect(nil_layer).to eq(plain)
    expect(plain.grep(/intent_layer/)).to be_empty
    expect(plain.size).to eq(1)
    expect(asked.size).to eq(1)
    expect(asked.first).to include("intent_layer")
  end
end
