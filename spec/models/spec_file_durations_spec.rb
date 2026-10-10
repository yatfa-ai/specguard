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

  # A layer-asked fixture where the all-layer ranking and the request-layer ranking DISAGREE: the
  # unit-heavy files outweigh `heavy_request_spec.rb` overall (and fill a limit of two), yet its
  # request-layer time is the largest.
  def layered_run
    observe(line_number: 1, spec_file_path: "spec/models/u1_spec.rb", intent_layer: "unit", duration: 5.0)
    observe(line_number: 2, spec_file_path: "spec/models/u2_spec.rb", intent_layer: "unit", duration: 5.0)
    3.times { |i| observe(line_number: 10 + i, spec_file_path: "spec/models/heavy_request_spec.rb", intent_layer: "request", duration: 1.0) }
    observe(line_number: 20, spec_file_path: "spec/models/heavy_request_spec.rb", intent_layer: "unit", duration: 0.5)
    # Two request-layer files that tie on layer time: path breaks the tie.
    observe(line_number: 30, spec_file_path: "spec/requests/b_spec.rb", intent_layer: "request", duration: 2.0)
    observe(line_number: 31, spec_file_path: "spec/requests/a_spec.rb", intent_layer: "request", duration: 2.0)
    # Declares nothing, but lives under spec/requests/: path decides nothing.
    observe(line_number: 40, spec_file_path: "spec/requests/login_spec.rb", intent_layer: nil, duration: 7.0)
  end

  describe ".for with layer:" do
    # @intent: { entity: "SpecFileDurations", action: "rank files by one declared layer", behavior: "under a layer the rollup is ranked by that layer's own time, with the layer's per-file counts, and a heavy-in-that-layer file outranks files that are heavier overall", layer: "unit" }
    it "ranks by the layer's time with the layer's own per-file counts" do
      layered_run

      durations = described_class.for(run, layer: "request")

      expect(durations.layer).to eq("request")
      expect(durations).to be_layer
      expect(durations.rows.map(&:path)).to eq(%w[spec/models/heavy_request_spec.rb spec/requests/a_spec.rb spec/requests/b_spec.rb])
      heavy = durations.rows.first
      expect(heavy.total_seconds).to eq(3.0)
      expect(heavy.recorded_count).to eq(3)
      expect(heavy.timed_count).to eq(3)
      expect(heavy.layer_counts).to eq(unit: 0, integration: 0, request: 3, system: 0, undeclared: 0)
      expect(durations.rows.map { it.layer_counts.values.sum }).to eq(durations.rows.map(&:recorded_count))
    end

    # @intent: { entity: "SpecFileDurations", action: "rank files by one declared layer", behavior: "the unasked top two excludes the request-heavy file the layer-asked top two ranks first, because the layer rides into the query before the limit", layer: "unit" }
    it "applies the layer before the limit, so a file below the unasked cut can lead" do
      layered_run

      expect(described_class.for(run, limit: 2).rows.map(&:path)).not_to include("spec/models/heavy_request_spec.rb")
      expect(described_class.for(run, limit: 2, layer: "request").rows.map(&:path).first)
        .to eq("spec/models/heavy_request_spec.rb")
    end

    # @intent: { entity: "SpecFileDurations", action: "count the files in a layer", behavior: "under a layer file_count is read by index as the number of files holding that layer, never a trailing layer count, and truncated? is honest against it", layer: "unit" }
    it "reads the layer's file count by index and truncates honestly against it" do
      layered_run

      durations = described_class.for(run, limit: 2, layer: "request")

      expect(durations.rows.size).to eq(2)
      # Three request files; the first row's trailing request count is 3 too, so use another layer to
      # prove the index, not the tail, is read: `undeclared` has 1 file and the unit layer 3.
      expect(durations.file_count).to eq(3)
      expect(durations).to be_truncated
      expect(described_class.for(run, limit: 5, layer: "request")).not_to be_truncated
      expect(described_class.for(run, layer: "unit").file_count).to eq(3)
      expect(described_class.for(run, layer: "undeclared").file_count).to eq(1)
    end

    # @intent: { entity: "SpecFileDurations", action: "select the undeclared layer", behavior: "undeclared selects intent_layer IS NULL rows and a file under spec/requests with no declared layer is undeclared, not request", layer: "unit" }
    it "selects undeclared by the stored layer, never the path" do
      layered_run

      undeclared = described_class.for(run, layer: "undeclared")

      expect(undeclared.rows.map(&:path)).to eq(["spec/requests/login_spec.rb"])
      expect(described_class.for(run, layer: "request").rows.map(&:path)).not_to include("spec/requests/login_spec.rb")
    end

    # @intent: { entity: "SpecFileDurations", action: "answer a layer nobody declared", behavior: "a layer with no examples is an empty answer that is still recorded, while a run with no rows is not recorded with or without the layer", layer: "unit" }
    it "keeps recorded? a run-level fact when a layer matches nothing" do
      layered_run

      empty = described_class.for(run, layer: "system")
      expect(empty.rows).to eq([])
      expect(empty.file_count).to eq(0)
      expect(empty).to be_recorded

      bare = create_test_run(repository: repository, commit_sha: "bare00000001")
      expect(described_class.for(bare, layer: "request")).not_to be_recorded
      expect(described_class.for(bare)).not_to be_recorded
    end

    # @intent: { entity: "SpecFileDurations", action: "leave the unasked rollup unchanged", behavior: "without a layer the presenter carries no layer and decides recorded? from its rows, reading nothing new", layer: "unit" }
    it "is unchanged when unasked" do
      layered_run

      durations = described_class.for(run)

      expect(durations.layer).to be_nil
      expect(durations).not_to be_layer
      expect(durations).to be_recorded
      expect(durations.file_count).to eq(6)
    end
  end
end
