# frozen_string_literal: true

require "rails_helper"

# `layer:` on the four `SpecObservation::RunPairGrowthReads` methods and their presenters (SPGD-1780).
RSpec.describe "run-pair growth reads — layer:" do
  let(:repository) { create_repository }
  let(:previous_run) { create_test_run(repository: repository, commit_sha: "prevlayer001", total_specs_count: 3) }
  let(:latest_run) { create_test_run(repository: repository, commit_sha: "latelayer001", total_specs_count: 4) }

  def observe(run, path:, line:, layer:, duration: 1.0)
    run.spec_observations.create!(
      repository: repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  before do
    observe(previous_run, path: "spec/models/a_spec.rb", line: 1, layer: "unit")
    observe(previous_run, path: "spec/models/a_spec.rb", line: 2, layer: "request")
    observe(latest_run, path: "spec/models/a_spec.rb", line: 1, layer: "unit")
    observe(latest_run, path: "spec/models/a_spec.rb", line: 2, layer: "request")
    observe(latest_run, path: "spec/models/a_spec.rb", line: 3, layer: "request")
    observe(latest_run, path: "spec/jobs/b_spec.rb", line: 1, layer: "request")
  end


  it "keeps the nil-layer statements byte-identical to the un-narrowed ones" do
    plain = queries_against("spec_observations") { SpecObservation.directory_growth_between(latest_run, previous_run) }
    nil_layer = queries_against("spec_observations") do
      SpecObservation.directory_growth_between(latest_run, previous_run, layer: nil)
    end
    expect(nil_layer).to eq(plain)
    expect(plain.first).not_to include("intent_layer")
  end

  it "narrows all four reads and their window totals to the layer" do
    rows = SpecObservation.directory_growth_between(latest_run, previous_run, layer: "request")
    expect(rows.to_h { |path, prev, latest, *| [path, [prev, latest]] })
      .to eq("spec/models" => [1, 2], "spec/jobs" => [0, 1])
    expect(rows.first[3..]).to eq([2, 1, 3])

    files = SpecObservation.file_growth_between(latest_run, previous_run, "spec/models", layer: "request")
    expect(files.first[3..]).to eq([1, 1, 2])

    seconds = SpecObservation.directory_runtime_growth_between(latest_run, previous_run, layer: "request")
    expect(seconds.first[7..]).to eq([2, 1, 3, 1, 3])

    file_seconds = SpecObservation.file_runtime_growth_between(latest_run, previous_run, "spec/models",
                                                               layer: "request")
    expect(file_seconds.first[7..]).to eq([1, 1, 2, 1, 2])
  end

  it "selects undeclared by the stored declaration" do
    rows = SpecObservation.directory_growth_between(latest_run, previous_run, layer: "undeclared")
    expect(rows).to eq([])
  end

  describe SpecDirectoryGrowth do
    it "is comparable and empty, not neither_recorded, for a layer in neither run" do
      growth = described_class.for(latest_run, previous_run, layer: "system")
      expect(growth).to be_comparable
      expect(growth.rows).to eq([])
      expect(growth).to be_layer_empty
      expect(growth.layer).to eq("system")
      expect(described_class.for(latest_run, previous_run).layer).to be_nil
    end

    it "keeps the unrecorded state at run grain when a layer is asked" do
      bare = create_test_run(repository: repository, commit_sha: "bare00000001", total_specs_count: 5)
      expect(described_class.for(latest_run, bare, layer: "request").state).to eq(:previous_unrecorded)
      expect(described_class.for(bare, previous_run, layer: "request").state).to eq(:latest_unrecorded)
    end
  end

  describe SpecDirectoryRuntimeGrowth do
    it "is comparable and empty for a layer in neither run" do
      growth = described_class.for(latest_run, previous_run, layer: "system")
      expect(growth).to be_comparable
      expect(growth).to be_layer_empty
    end

    it "is untimed only on a side that has the layer's examples" do
      previous_run.spec_observations.where(intent_layer: "request").update_all(duration_seconds: nil)
      expect(described_class.for(latest_run, previous_run, layer: "request").state).to eq(:previous_untimed)
      expect(described_class.for(latest_run, previous_run, layer: "unit").state).to eq(:comparable)
    end
  end
end
