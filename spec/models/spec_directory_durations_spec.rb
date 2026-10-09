# frozen_string_literal: true

require "rails_helper"

# The by-directory rollup's presenter, with a declared layer asked (SPGD-1761). Its structural risks
# are the tuple contract with `SpecObservation.directory_durations_in` (the declared-layer operands
# ride AFTER `COUNT(*) OVER ()`, so the area count is read by INDEX) and `#recorded?`, which must be a
# run-level fact once a layer is asked.
RSpec.describe SpecDirectoryDurations do
  let(:repository) { create_repository }
  let(:run) { create_test_run(repository: repository) }

  def observe(line_number:, spec_file_path:, intent_layer: nil, duration: 1.0)
    SpecObservation.create!(
      test_run: run, repository: repository, name: "example #{line_number}",
      example_id: "./#{spec_file_path}[1:#{line_number}]", file_path: spec_file_path,
      spec_file_path: spec_file_path, line_number: line_number, status: "unannotated",
      duration_seconds: duration, intent_layer: intent_layer
    )
  end

  # The all-layer and request-layer rankings DISAGREE: the unit-heavy areas outweigh
  # `spec/models` overall (and fill a limit of two), yet its request-layer time is the largest.
  def layered_run
    observe(line_number: 1, spec_file_path: "spec/unit_a/a_spec.rb", intent_layer: "unit", duration: 5.0)
    observe(line_number: 2, spec_file_path: "spec/unit_b/b_spec.rb", intent_layer: "unit", duration: 5.0)
    3.times { |i| observe(line_number: 10 + i, spec_file_path: "spec/models/heavy_spec.rb", intent_layer: "request", duration: 1.0) }
    observe(line_number: 20, spec_file_path: "spec/models/heavy_spec.rb", intent_layer: "unit", duration: 0.5)
    # Two request areas that tie on layer time: path breaks the tie.
    observe(line_number: 30, spec_file_path: "spec/requests_b/b_spec.rb", intent_layer: "request", duration: 2.0)
    observe(line_number: 31, spec_file_path: "spec/requests_a/a_spec.rb", intent_layer: "request", duration: 2.0)
    # Declares nothing, but lives under spec/requests/: path decides nothing.
    observe(line_number: 40, spec_file_path: "spec/requests/login_spec.rb", intent_layer: nil, duration: 7.0)
  end

  describe ".for with layer:" do
    # @intent: { entity: "SpecDirectoryDurations", action: "rank areas by one declared layer", behavior: "under a layer the rollup is ranked by that layer's own time, with the layer's per-area counts, and a heavy-in-that-layer area outranks areas that are heavier overall", layer: "unit" }
    it "ranks by the layer's time with the layer's own per-area counts" do
      layered_run

      durations = described_class.for(run, layer: "request")

      expect(durations.layer).to eq("request")
      expect(durations).to be_layer
      expect(durations.rows.map(&:path)).to eq(%w[spec/models spec/requests_a spec/requests_b])
      heavy = durations.rows.first
      expect(heavy.total_seconds).to eq(3.0)
      expect(heavy.recorded_count).to eq(3)
      expect(heavy.timed_count).to eq(3)
      expect(heavy.layer_counts).to eq(unit: 0, integration: 0, request: 3, system: 0, undeclared: 0)
      expect(durations.rows.map { it.layer_counts.values.sum }).to eq(durations.rows.map(&:recorded_count))
    end

    # @intent: { entity: "SpecDirectoryDurations", action: "rank areas by one declared layer", behavior: "the unasked top two excludes the request-heavy area the layer-asked top two ranks first, because the layer rides into the query before the limit", layer: "unit" }
    it "applies the layer before the limit, so an area below the unasked cut can lead" do
      layered_run

      expect(described_class.for(run, limit: 2).rows.map(&:path)).not_to include("spec/models")
      expect(described_class.for(run, limit: 2, layer: "request").rows.map(&:path).first).to eq("spec/models")
    end

    # @intent: { entity: "SpecDirectoryDurations", action: "count the areas in a layer", behavior: "under a layer directory_count is read by index as the number of areas holding that layer, never a trailing layer count, and truncated? is honest against it", layer: "unit" }
    it "reads the layer's area count by index and truncates honestly against it" do
      layered_run

      durations = described_class.for(run, limit: 2, layer: "request")

      expect(durations.rows.size).to eq(2)
      expect(durations.directory_count).to eq(3)
      expect(durations).to be_truncated
      expect(described_class.for(run, limit: 5, layer: "request")).not_to be_truncated
      expect(described_class.for(run, layer: "unit").directory_count).to eq(3)
      expect(described_class.for(run, layer: "undeclared").directory_count).to eq(1)
    end

    # @intent: { entity: "SpecDirectoryDurations", action: "select the undeclared layer", behavior: "undeclared selects intent_layer IS NULL rows and an area under spec/requests with no declared layer is undeclared, not request", layer: "unit" }
    it "selects undeclared by the stored layer, never the path" do
      layered_run

      expect(described_class.for(run, layer: "undeclared").rows.map(&:path)).to eq(["spec/requests"])
      expect(described_class.for(run, layer: "request").rows.map(&:path)).not_to include("spec/requests")
    end

    # @intent: { entity: "SpecDirectoryDurations", action: "answer a layer nobody declared", behavior: "a layer with no examples is an empty answer that is still recorded, while a run with no rows is not recorded with or without the layer", layer: "unit" }
    it "keeps recorded? a run-level fact when a layer matches nothing" do
      layered_run

      empty = described_class.for(run, layer: "system")
      expect(empty.rows).to eq([])
      expect(empty.directory_count).to eq(0)
      expect(empty).to be_recorded

      bare = create_test_run(repository: repository, commit_sha: "bare00000001")
      expect(described_class.for(bare, layer: "request")).not_to be_recorded
      expect(described_class.for(bare)).not_to be_recorded
    end

    # @intent: { entity: "SpecDirectoryDurations", action: "leave the unasked rollup unchanged", behavior: "without a layer the presenter carries no layer and decides recorded? from its rows, reading nothing new", layer: "unit" }
    it "is unchanged when unasked" do
      layered_run

      durations = described_class.for(run)

      expect(durations.layer).to be_nil
      expect(durations).not_to be_layer
      expect(durations).to be_recorded
      expect(durations.directory_count).to eq(6)
    end
  end
end
