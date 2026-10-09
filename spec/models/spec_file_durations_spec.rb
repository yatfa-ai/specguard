# frozen_string_literal: true

require "rails_helper"

# The by-file rollup's presenter. Its one structural risk is the tuple contract with
# `SpecObservation.file_durations_in`: the declared-layer operands ride AFTER `COUNT(*) OVER ()`,
# so reading the file count off the end of the tuple would serve a layer count as a file count.
RSpec.describe SpecFileDurations do
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

  # Mixed on purpose: two layers declared, some NULL, and one file declaring nothing. The per-file
  # mix must sum to the file's `recorded_count`, and the path must decide nothing.
  def mixed_run
    observe(line_number: 1, spec_file_path: "spec/models/a_spec.rb", intent_layer: "unit", duration: 9.0)
    observe(line_number: 2, spec_file_path: "spec/models/a_spec.rb", intent_layer: "request", duration: 9.0)
    observe(line_number: 3, spec_file_path: "spec/models/a_spec.rb", intent_layer: nil, duration: 9.0)
    observe(line_number: 4, spec_file_path: "spec/requests/b_spec.rb", intent_layer: nil, duration: 4.0)
    observe(line_number: 5, spec_file_path: "spec/requests/b_spec.rb", intent_layer: "unit", duration: 4.0)
    observe(line_number: 6, spec_file_path: "spec/c_spec.rb", intent_layer: nil, duration: 1.0)
  end

  # @intent: { entity: "SpecFileDurations", action: "roll a run up by file", behavior: "each row serves five declared-layer counts that sum to its recorded count, counted off the stored layer and never the path", layer: "unit" }
  it "serves each file's declared-layer counts, summing to its recorded count" do
    mixed_run

    rows = described_class.for(run).rows.to_h { [it.path, it] }

    expect(rows.fetch("spec/models/a_spec.rb").layer_counts)
      .to eq(unit: 1, integration: 0, request: 1, system: 0, undeclared: 1)
    expect(rows.fetch("spec/requests/b_spec.rb").layer_counts)
      .to eq(unit: 1, integration: 0, request: 0, system: 0, undeclared: 1)
    expect(rows.fetch("spec/c_spec.rb").layer_counts)
      .to eq(unit: 0, integration: 0, request: 0, system: 0, undeclared: 1)
    expect(rows.values).to all(satisfy { |row| row.layer_counts.values.sum == row.recorded_count })
    expect(rows.fetch("spec/models/a_spec.rb").layer_counts_label).to eq("unit 1 · request 1 · undeclared 1")
    expect(rows.fetch("spec/c_spec.rb").layer_counts_label).to eq("undeclared 1")
  end

  # REGRESSION PIN: with the layer columns appended, `.last` of a tuple is a layer count. Three
  # files and a limit of two, so `truncated?` is true and the file count (3) differs from both the
  # row count (2) and every layer count on the first row.
  # @intent: { entity: "SpecFileDurations", action: "count the files a run touched", behavior: "file_count stays the number of files the run touched, not a trailing layer count, with the list truncated below it", layer: "unit" }
  it "reads the file count by index, not off the end of the tuple" do
    mixed_run

    durations = described_class.for(run, limit: 2)

    expect(durations.rows.size).to eq(2)
    expect(durations.file_count).to eq(3)
    expect(durations).to be_truncated
    # The first (heaviest) row's last tuple element is its `undeclared` count — 1 — which is what
    # `.last` would have served as the file count.
    expect(durations.rows.first.layer_counts.fetch(:undeclared)).not_to eq(durations.file_count)
  end

  # @intent: { entity: "SpecFileDurations", action: "roll a run up by file", behavior: "a run that recorded nothing yields no rows and a zero file count", layer: "unit" }
  it "reads zero files for a run that recorded nothing" do
    durations = described_class.for(run)

    expect(durations.rows).to eq([])
    expect(durations.file_count).to eq(0)
  end
end
