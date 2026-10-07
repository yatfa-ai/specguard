# frozen_string_literal: true

require "rails_helper"

# The `latest_run.layer_counts` block on `GET /api/v1/repository` — the RUN-WIDE declared-layer mix.
#
# The stored per-example `@intent` layer was already served per area (`spec_directories`, ten areas
# at most), per file and per example, and never for the whole run: "how many of this run's tests are
# unit / integration / request / system / undeclared?" was unanswerable. This is that figure, a
# SIBLING of `intent_readings` (which stays pinned at four keys), counted in the same single
# aggregate row so the endpoint pays no read for it.
#
# Operands only. The layer is what an annotation DECLARED — the path is never consulted, and an
# undeclared example is not an unreadable one.
RSpec.describe "GET /api/v1/repository — latest_run.layer_counts", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }
  let(:layer_keys) { %w[unit integration request system undeclared] }

  def get_repository(key: api_key, query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{key.raw_token}" }

    response.parsed_body
  end

  def latest_run(**) = get_repository(**)["latest_run"]

  def layer_counts(**) = latest_run(**)["layer_counts"]

  def ingest(repo, specs, commit_sha: "feedfacecafe0001", branch: "main")
    payload = Ingest::Payload.new(
      { "commit_sha" => commit_sha, "branch" => branch, "duration_seconds" => 60.0,
        "specs" => specs.map(&:deep_stringify_keys) }
    )
    raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

    Ingest::RunRecorder.record(repo, payload.test_run_attributes, specs: payload.specs)
  end

  describe "a mixed run" do
    before do
      ingest(repository,
             [# Declares `unit` but lives under spec/requests/ — the path must not move it.
              annotated_spec(file_path: "spec/requests/checkout_spec.rb", line_number: 1, layer: "unit"),
              annotated_spec(file_path: "spec/requests/refund_spec.rb", line_number: 2, layer: "unit"),
              annotated_spec(file_path: "spec/models/invoice_spec.rb", line_number: 3, layer: "request"),
              annotated_spec(file_path: "spec/features/pay_spec.rb", line_number: 4, layer: "system"),
              annotated_spec(file_path: "spec/services/sync_spec.rb", line_number: 5, layer: "integration"),
              # Declares nothing but lives under spec/requests/ — undeclared, never inferred `request`.
              unannotated_spec(file_path: "spec/requests/login_spec.rb", line_number: 6,
                               name: "Login rejects an expired card"),
              unannotated_spec(file_path: "spec/models/user_spec.rb", line_number: 7)])
    end

    # NEGATIVE FIRST: the path is never consulted.
    # @intent: { entity: "layer_counts", action: "count declared layers", behavior: "examples declaring unit under spec/requests count under unit and an undeclared example there counts undeclared, since the path is never consulted", layer: "request" }
    it "counts the layer each example declared and never the directory it lives in" do
      expect(layer_counts).to eq("unit" => 2, "integration" => 1, "request" => 1, "system" => 1,
                                 "undeclared" => 2)
    end

    # @intent: { entity: "layer_counts", action: "partition the recorded rows", behavior: "the five counts sum to intent_readings.recorded and are served in the closed enum order", layer: "request" }
    it "sums to the recorded population, in the declared order" do
      run = latest_run

      expect(run["layer_counts"].keys).to eq(layer_keys)
      expect(run["layer_counts"].values.sum).to eq(run["intent_readings"]["recorded"])
      expect(run["intent_readings"].keys).to contain_exactly("authored", "derived", "unreadable", "recorded")
    end

    # @intent: { entity: "layer_counts", action: "read the run once", behavior: "the layer mix rides the run-grain aggregate already issued, so the endpoint reads the run's rows exactly as often as before", layer: "request" }
    it "adds no read of spec_observations beyond the run-grain aggregate" do
      reads = observation_reads { get_repository }

      expect(reads.grep(ObservationGrainReads::RUN_READINGS_PROJECTION).length).to eq(1)
      expect(reads.grep(/run_layer_unit_count/).length).to eq(1)
      expect(reads.length).to eq(classified_observation_reads { get_repository })
    end
  end

  describe "a run with no per-example rows" do
    before { ingest_totals_only }

    def ingest_totals_only
      payload = Ingest::Payload.new({ "commit_sha" => "feedfacecafe0002", "branch" => "main",
                                      "duration_seconds" => 5.0, "specs" => [] })
      Ingest::RunRecorder.record(repository, payload.test_run_attributes.merge(total_specs_count: 10),
                                 specs: [])
    end

    # @intent: { entity: "layer_counts", action: "withhold an unmeasured mix", behavior: "a run that recorded no per-example rows serves a null layer mix rather than five zeros, the key present beside recorded zero", layer: "request" }
    it "serves null rather than five zeros" do
      run = latest_run

      expect(run).to have_key("layer_counts")
      expect(run["layer_counts"]).to be_nil
      expect(run["intent_readings"]["recorded"]).to eq(0)
    end
  end

  describe "a run with more than ten areas" do
    let(:declared) { %w[unit integration request system] }

    before do
      specs = (1..13).flat_map do |index|
        file = "spec/area_#{index}/thing_spec.rb"
        [annotated_spec(file_path: file, line_number: 1, layer: declared[index % 4]),
         annotated_spec(file_path: file, line_number: 2, layer: "unit"),
         unannotated_spec(file_path: file, line_number: 3)]
      end
      ingest(repository, specs)
    end

    # @intent: { entity: "layer_counts", action: "count the whole run", behavior: "with thirteen areas the run-wide counts equal the sum of every area's own layer_counts, proving the figure is not the ten-area head", layer: "request" }
    it "equals the sum of every area's counts, not the listed top ten" do
      run = latest_run(query: { limit: 10 })
      areas = (1..13).map { |index| "spec/area_#{index}" }
      summed = areas.map { |area| latest_run(query: { spec_directory: area })["spec_directory_files"]["layer_counts"] }
                    .each_with_object(Hash.new(0)) { |counts, total| counts.each { |layer, n| total[layer] += n } }

      expect(run["spec_directories"]["rows"].length).to be <= 10
      expect(run["layer_counts"]).to eq(summed)
      expect(run["layer_counts"].values.sum).to eq(39)
    end
  end
end
