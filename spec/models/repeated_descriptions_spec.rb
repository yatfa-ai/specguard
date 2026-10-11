# frozen_string_literal: true

require "rails_helper"

# The by-description rollup's presenter. Its one structural risk is the tuple contract with
# `SpecObservation.repeated_descriptions_in`: the declared-layer operands ride AFTER the three window
# totals, so reading those off the end of the tuple would serve layer counts as group totals.
RSpec.describe RepeatedDescriptions do
  let(:repository) { create_repository }
  let(:run) { create_test_run(repository: repository) }

  def observe(name:, line_number:, intent_layer: nil, duration: 1.0, spec_file_path: "spec/models/a_spec.rb")
    SpecObservation.create!(
      test_run: run, repository: repository, name: name,
      example_id: "./#{spec_file_path}[1:#{line_number}]", file_path: spec_file_path,
      spec_file_path: spec_file_path, line_number: line_number, status: "unannotated",
      duration_seconds: duration, intent_layer: intent_layer
    )
  end

  # Three repeated descriptions (so a limit below 3 truncates), layer counts that differ from the
  # window figures: group_count 3, repeated_recorded_count 8, repeated_timed_count 8.
  def mixed_run
    observe(name: "alpha", line_number: 1, intent_layer: "unit", duration: 9.0)
    observe(name: "alpha", line_number: 2, intent_layer: "request", duration: 9.0)
    observe(name: "alpha", line_number: 3, intent_layer: nil, duration: 9.0)
    observe(name: "beta", line_number: 4, intent_layer: "unit", duration: 4.0)
    observe(name: "beta", line_number: 5, intent_layer: "unit", duration: 4.0)
    observe(name: "beta", line_number: 6, intent_layer: "unit", duration: 4.0)
    observe(name: "gamma", line_number: 7, intent_layer: nil, duration: 1.0)
    observe(name: "gamma", line_number: 8, intent_layer: nil, duration: 1.0)
    observe(name: "single", line_number: 9, intent_layer: "system", duration: 1.0)
  end

  # @intent: { entity: "RepeatedDescriptions", action: "roll a run up by description", behavior: "each row serves five declared-layer counts that sum to its recorded count, counted off the stored layer and never the path", layer: "unit" }
  it "serves each description's declared-layer counts, summing to its recorded count" do
    mixed_run

    rows = described_class.for(run).rows.to_h { [it.name, it] }

    expect(rows.fetch("alpha").layer_counts)
      .to eq(unit: 1, integration: 0, request: 1, system: 0, undeclared: 1)
    expect(rows.fetch("beta").layer_counts)
      .to eq(unit: 3, integration: 0, request: 0, system: 0, undeclared: 0)
    expect(rows.fetch("gamma").layer_counts)
      .to eq(unit: 0, integration: 0, request: 0, system: 0, undeclared: 2)
    expect(rows.values).to all(satisfy { |row| row.layer_counts.values.sum == row.recorded_count })
    expect(rows.fetch("alpha").layer_counts_label).to eq("unit 1 · request 1 · undeclared 1")
    expect(rows.fetch("gamma").layer_counts_label).to eq("undeclared 2")
  end

  # REGRESSION PIN: with the layer columns appended, `.last(3)` of a tuple is three layer counts.
  # Limit 2 truncates the list, and the window figures (3 / 8 / 8) differ from the first row's
  # trailing layer counts.
  # @intent: { entity: "RepeatedDescriptions", action: "count the repeated population", behavior: "the window figures stay the whole repeated population's totals, not trailing layer counts, with the list truncated below them", layer: "unit" }
  it "reads the window figures by index, not off the end of the tuple" do
    mixed_run

    repeated = described_class.for(run, limit: 2)

    expect(repeated.rows.size).to eq(2)
    expect(repeated).to be_truncated
    expect(repeated.group_count).to eq(3)
    expect(repeated.repeated_recorded_count).to eq(8)
    expect(repeated.repeated_timed_count).to eq(8)
    expect(repeated.rows.first.layer_counts.values.last(3)).not_to eq([3, 8, 8])
  end

  # @intent: { entity: "RepeatedDescriptions", action: "roll a run up by description", behavior: "a run with nothing repeated yields no rows and zero window figures", layer: "unit" }
  it "reads zero for a run that repeated nothing" do
    observe(name: "only one", line_number: 1)

    repeated = described_class.for(run)

    expect(repeated.rows).to eq([])
    expect([repeated.group_count, repeated.repeated_recorded_count, repeated.repeated_timed_count]).to eq([0, 0, 0])
  end
  # The layer ask (SPGD-1763): descriptions repeated WITHIN one declared layer.
  describe ".for layer:" do
    def layered_run
      # "loop": 4 request examples at 3s = 12s, repeated inside request.
      4.times { |i| observe(name: "loop", line_number: i + 1, intent_layer: "request", duration: 3.0) }
      # Ten unit descriptions repeated twice at 7s each (14s per group, above loop's 12s) fill the unasked top ten.
      10.times do |g|
        2.times { |i| observe(name: "unit-#{g}", line_number: 100 + g * 2 + i, intent_layer: "unit", duration: 7.0) }
      end
      # One request + one unit example: repeated across layers, within neither.
      observe(name: "straddle", line_number: 200, intent_layer: "request", duration: 1.0)
      observe(name: "straddle", line_number: 201, intent_layer: "unit", duration: 1.0)
      # An unnamed request example and an undeclared repeated pair.
      observe(name: nil, line_number: 300, intent_layer: "request", duration: 1.0)
      2.times { |i| observe(name: "plain", line_number: 400 + i, intent_layer: nil, duration: 0.5) }
    end

    # @intent: { entity: "RepeatedDescriptions", action: "find descriptions repeated within a declared layer", behavior: "a description repeated four times inside the request layer is absent from the unasked default top ten and ranks first under the request layer", layer: "request" }
    it "ranks within the layer before the limit, surfacing a group the unasked top ten drops" do
      layered_run

      unasked = described_class.for(run)
      expect(unasked.rows.size).to eq(SpecObservation::REPEATED_DESCRIPTIONS_LIMIT)
      expect(unasked.rows.map(&:name)).not_to include("loop")

      asked = described_class.for(run, layer: "request")
      expect(asked.rows.map(&:name)).to eq(["loop"])
      expect(asked.rows.first.layer_counts).to eq(unit: 0, integration: 0, request: 4, system: 0, undeclared: 0)
      expect(asked.rows.first).to have_attributes(recorded_count: 4, timed_count: 4, total_seconds: 12.0)
      expect(asked.layer).to eq("request")
      expect(asked).to be_layer
    end

    # @intent: { entity: "RepeatedDescriptions", action: "find descriptions repeated within a declared layer", behavior: "a description with exactly one request and one unit example is repeated within neither layer, so it is absent under both and present unasked", layer: "request" }
    it "does not count a description repeated only across layers" do
      layered_run

      expect(described_class.for(run, limit: 100).rows.map(&:name)).to include("straddle")
      expect(described_class.for(run, limit: 100, layer: "request").rows.map(&:name)).not_to include("straddle")
      expect(described_class.for(run, limit: 100, layer: "unit").rows.map(&:name)).not_to include("straddle")
    end

    # @intent: { entity: "RepeatedDescriptions", action: "count within a declared layer", behavior: "under a layer the window totals and the presence counts describe that layer's population and named_row_count reconciles with its recorded and unnamed counts", layer: "request" }
    it "reads the window totals by index over the layer's population" do
      layered_run

      asked = described_class.for(run, limit: 100, layer: "request")

      expect(asked.group_count).to eq(1)
      expect(asked.repeated_recorded_count).to eq(4)
      expect(asked.repeated_timed_count).to eq(4)
      # 4 loop + 1 straddle + 1 unnamed request example.
      expect(asked.recorded_count).to eq(6)
      expect(asked.unnamed_row_count).to eq(1)
      expect(asked.named_row_count).to eq(5)
      expect(asked.recorded_count - asked.unnamed_row_count).to eq(asked.named_row_count)
      expect(described_class.for(run, limit: 100, layer: "undeclared").rows.map(&:name)).to eq(["plain"])
    end

    # @intent: { entity: "RepeatedDescriptions", action: "separate an empty layer from an unrecorded run", behavior: "a layer no example declared is an empty answer that is still recorded, while a run with no observation rows is not recorded with or without the layer", layer: "system" }
    it "keeps recorded? a run-level fact when a layer is asked" do
      layered_run

      empty = described_class.for(run, layer: "system")
      expect(empty.rows).to be_empty
      expect(empty.group_count).to eq(0)
      expect(empty).to be_recorded
      expect(empty).to be_layer_empty

      bare = described_class.for(create_test_run(repository: repository), layer: "request")
      expect(bare).not_to be_recorded
      expect(described_class.for(create_test_run(repository: repository))).not_to be_recorded
    end

    # @intent: { entity: "RepeatedDescriptions", action: "find descriptions repeated within a declared layer", behavior: "the unasked read issues exactly the two statements it always did and the layer-asked read issues the same two plus at most the run-level intent readings read", layer: "request" }
    it "adds no statement unasked and at most the intent_readings read when asked" do
      layered_run
      fresh = -> { TestRun.find(run.id) }

      unasked = queries_against("spec_observations") { described_class.for(fresh.call) }
      asked = queries_against("spec_observations") { described_class.for(fresh.call, layer: "request") }

      expect(unasked.size).to eq(2)
      expect(asked.size).to be_between(2, 3)
      expect(asked.count { it.include?("GROUP BY \"spec_observations\".\"name\"") }).to eq(1)
      expect(asked.first).to include("intent_layer")
    end
  end
end
