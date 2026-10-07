# frozen_string_literal: true

require "rails_helper"

# The `latest_run.layer_durations` block on `GET /api/v1/repository` — WHERE THE RUN'S TIME GOES by
# declared layer, the sibling of `layer_counts` (SPGD-1669) computed in the SAME single run aggregate.
#
# Operands only: a sum of example durations (machine time, not wall clock) and how many examples
# that sum covers. The layer is what an annotation DECLARED — the path is never consulted.
RSpec.describe "GET /api/v1/repository — latest_run.layer_durations", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }
  let(:layer_keys) { %w[unit integration request system undeclared] }

  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  def latest_run(**) = get_repository(**)["latest_run"]

  def ingest(repo, specs, commit_sha: "feedfacecafe0101", branch: "main")
    payload = Ingest::Payload.new(
      { "commit_sha" => commit_sha, "branch" => branch, "duration_seconds" => 60.0,
        "specs" => specs.map(&:deep_stringify_keys) }
    )
    raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

    Ingest::RunRecorder.record(repo, payload.test_run_attributes, specs: payload.specs)
  end

  describe "a mixed run, timed and untimed, every layer" do
    before do
      ingest(repository,
             [annotated_spec(file_path: "spec/requests/a_spec.rb", line_number: 1, layer: "unit", duration: 1.5),
              annotated_spec(file_path: "spec/requests/b_spec.rb", line_number: 2, layer: "unit", duration: 2.0),
              annotated_spec(file_path: "spec/requests/c_spec.rb", line_number: 3, layer: "unit", duration: nil),
              annotated_spec(file_path: "spec/models/d_spec.rb", line_number: 4, layer: "request", duration: 10.0),
              annotated_spec(file_path: "spec/features/e_spec.rb", line_number: 5, layer: "system", duration: 30.25),
              # integration: declared, but never timed.
              annotated_spec(file_path: "spec/services/f_spec.rb", line_number: 6, layer: "integration",
                             duration: nil),
              unannotated_spec(file_path: "spec/requests/g_spec.rb", line_number: 7, duration: 0.25),
              unannotated_spec(file_path: "spec/models/h_spec.rb", line_number: 8, duration: nil)])
    end

    # @intent: { entity: "layer_durations", action: "sum example time by declared layer", behavior: "each layer serves the sum of its timed examples' durations and how many were timed, keyed by the five layers in enum order, with the path never consulted", layer: "request" }
    it "serves the five layers in order with summed seconds and timed counts" do
      durations = latest_run["layer_durations"]

      expect(durations.keys).to eq(layer_keys)
      expect(durations["unit"]).to eq("total_seconds" => 3.5, "timed_count" => 2)
      expect(durations["request"]).to eq("total_seconds" => 10.0, "timed_count" => 1)
      expect(durations["system"]).to eq("total_seconds" => 30.25, "timed_count" => 1)
      expect(durations["undeclared"]).to eq("total_seconds" => 0.25, "timed_count" => 1)
    end

    # @intent: { entity: "layer_durations", action: "withhold an unmeasured layer total", behavior: "a layer none of whose examples was timed serves total_seconds null and timed_count 0, never 0 seconds", layer: "request" }
    it "serves null, not zero, for a layer with no timed example" do
      expect(latest_run["layer_durations"]["integration"]).to eq("total_seconds" => nil, "timed_count" => 0)
    end

    # @intent: { entity: "layer_durations", action: "bound by layer_counts and total the run", behavior: "per layer timed_count never exceeds layer_counts and the five totals, nil as zero, sum to the run's summed duration_seconds", layer: "request" }
    it "is bounded by layer_counts and sums to the run's recorded durations" do
      run = latest_run
      durations = run["layer_durations"]

      layer_keys.each do |layer|
        expect(durations[layer]["timed_count"]).to be <= run["layer_counts"][layer]
      end
      expect(durations.values.sum { it["total_seconds"].to_f })
        .to be_within(1e-9).of(SpecObservation.where(test_run_id: repository.test_runs.last.id).sum(:duration_seconds))
    end

    # @intent: { entity: "layer_durations", action: "read the run once", behavior: "the per-layer time rides the single run-grain aggregate already issued, carrying the new aliases, so the endpoint reads the run's rows exactly as often as before", layer: "request" }
    it "adds no read of spec_observations beyond the run-grain aggregate" do
      reads = observation_reads { get_repository }

      expect(reads.grep(ObservationGrainReads::RUN_READINGS_PROJECTION).length).to eq(1)
      expect(reads.grep(/run_layer_unit_count/).length).to eq(1)
      expect(reads.grep(/run_layer_unit_seconds/).length).to eq(1)
      expect(reads.grep(/run_layer_unit_count/).first).to include("run_layer_undeclared_timed_count")
      expect(reads.length).to eq(classified_observation_reads { get_repository })
    end

    # @intent: { entity: "layer_durations", action: "sit beside layer_counts", behavior: "layer_durations is a sibling key of layer_counts and leaves the four-key intent_readings block unchanged", layer: "request" }
    it "is a sibling key and leaves intent_readings pinned at four keys" do
      run = latest_run

      expect(run).to have_key("layer_durations")
      expect(run["layer_counts"].keys).to eq(layer_keys)
      expect(run["intent_readings"].keys).to contain_exactly("authored", "derived", "unreadable", "recorded")
    end
  end

  describe "a run with no per-example rows" do
    before do
      payload = Ingest::Payload.new({ "commit_sha" => "feedfacecafe0102", "branch" => "main",
                                      "duration_seconds" => 5.0, "specs" => [] })
      Ingest::RunRecorder.record(repository, payload.test_run_attributes.merge(total_specs_count: 10), specs: [])
    end

    # @intent: { entity: "layer_durations", action: "withhold an unmeasured run", behavior: "a run that recorded no per-example rows serves layer_durations null with the key present", layer: "request" }
    it "serves null with the key present" do
      run = latest_run

      expect(run).to have_key("layer_durations")
      expect(run["layer_durations"]).to be_nil
    end
  end

  describe "a run with more than ten areas" do
    let(:declared) { %w[unit integration request system] }

    before do
      specs = (1..13).flat_map do |index|
        file = "spec/area_#{index}/thing_spec.rb"
        [annotated_spec(file_path: file, line_number: 1, layer: declared[index % 4], duration: index.to_f),
         annotated_spec(file_path: file, line_number: 2, layer: "unit", duration: 0.5),
         unannotated_spec(file_path: file, line_number: 3, duration: 0.25)]
      end
      ingest(repository, specs)
    end

    # @intent: { entity: "layer_durations", action: "total the whole run", behavior: "with thirteen areas the run-wide per-layer seconds equal the sum of every area's own timed rows per layer, proving the figure is not the ten-area head", layer: "request" }
    it "covers the whole run, not the listed top ten" do
      run = latest_run(query: { limit: 10 })
      expected = Hash.new(0.0)
      (1..13).each do |index|
        expected[declared[index % 4]] += index.to_f
        expected["unit"] += 0.5
        expected["undeclared"] += 0.25
      end

      expect(run["spec_directories"]["rows"].length).to be <= 10
      layer_keys.each do |layer|
        expect(run["layer_durations"][layer]["total_seconds"]).to be_within(1e-9).of(expected[layer])
      end
      expect(run["layer_durations"].values.sum { it["timed_count"] }).to eq(39)
    end
  end

  describe "the Overview panel" do
    before do
      ingest(repository,
             [annotated_spec(file_path: "spec/requests/a_spec.rb", line_number: 1, layer: "unit", duration: 1.5),
              annotated_spec(file_path: "spec/models/d_spec.rb", line_number: 4, layer: "request", duration: 70.0),
              unannotated_spec(file_path: "spec/models/h_spec.rb", line_number: 8, duration: nil)])
    end

    # @intent: { entity: "TestRun", action: "share one aggregate between panel and API", behavior: "TestRun#layer_durations equals the served latest_run.layer_durations, both read from the one memoized aggregate", layer: "request" }
    it "computes the panel's figures from the same memoized aggregate the API serves" do
      served = latest_run["layer_durations"]
      run = repository.test_runs.last

      expect(run.layer_durations.transform_keys(&:to_s).transform_values { it.transform_keys(&:to_s) }).to eq(served)
      expect(run.layer_durations).to equal(run.layer_durations)
      expect(SpecDirectoryDurations.layer_durations_label(run.layer_durations, run.layer_counts))
        .to eq("unit 1.50s (1 of 1 timed) · request 1m 10s (1 of 1 timed) · undeclared not reported (0 of 1 timed)")
    end
  end
end
