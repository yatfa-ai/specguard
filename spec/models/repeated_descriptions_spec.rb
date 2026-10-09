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
end
