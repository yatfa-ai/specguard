# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the four run-over-run area blocks of `GET /api/v1/repository` (SPGD-1780):
# `directory_run_growth`, `directory_runtime_growth`, `directory_run_file_growth` and
# `directory_runtime_file_growth`. The layer is what each example's own `@intent` declared, never
# inferred from the path. Rows are written by `Ingest::RunRecorder`, so every state is one a real client
# produces.
RSpec.describe "GET /api/v1/repository — ?layer= on the run-over-run area blocks", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def get_repository(query: {})
    token = repository.api_keys.create!.raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  def ingest(specs, commit_sha:, at:, total: nil)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: total || specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at)
    run
  end

  # `[["spec/models", "request", 5, 2.0], ...]` — that many examples of that layer in that area, each in
  # its own file named for the layer so the file grain is falsifiable. A nil layer is undeclared.
  def examples(spec_list)
    spec_list.flat_map do |directory, layer, count, seconds|
      Array.new(count) do |index|
        file = "#{directory}/#{layer || "plain"}_#{index + 1}_spec.rb"
        if layer
          annotated_spec(file_path: file, line_number: index + 1, layer: layer, duration: seconds,
                         name: "#{directory} #{layer} #{index + 1}")
        else
          unannotated_spec(file_path: file, line_number: index + 1, duration: seconds,
                           name: "#{directory} plain #{index + 1}")
        end
      end
    end
  end

  def two_runs(previous:, latest:)
    ingest(examples(previous), commit_sha: "previous0001", at: 20.days.ago)
    ingest(examples(latest), commit_sha: "latest000001", at: 10.days.ago)
  end

  def row_at(block, path) = block["rows"].find { |row| row["path"] == path }

  # spec/models: +5 request, -5 unit (±0 unasked). spec/jobs: +2 request. spec/services: unit only, -1.
  # Request time: spec/models 1×2s → 6×3s; spec/jobs 0 → 2×1s.
  def moving_runs
    two_runs(
      previous: [["spec/models", "request", 1, 2.0], ["spec/models", "unit", 8, 0.5],
                 ["spec/services", "unit", 3, 1.0]],
      latest: [["spec/models", "request", 6, 3.0], ["spec/models", "unit", 3, 0.5],
               ["spec/jobs", "request", 2, 1.0], ["spec/services", "unit", 2, 1.0]]
    )
  end

  describe "a layer both runs have examples of" do
    before { moving_runs }

    # @intent: { entity: "directory_run_growth", action: "narrow the area rollup to a layer", behavior: "?layer=request serves per-area counts of declared request examples, ranked by that layer's movement, where unasked the same area nets to zero", layer: "request" }
    it "counts the layer's examples per area and ranks by the layer's movement" do
      unasked = get_repository["directory_run_growth"]
      expect(row_at(unasked, "spec/models")).to include("baseline_count" => 9, "anchor_count" => 9, "change" => 0)
      expect(unasked).not_to have_key("layer")

      asked = get_repository(query: { layer: "request" })["directory_run_growth"]
      expect(asked["layer"]).to eq("request")
      # spec/services holds only unit examples: it is not an area of the request layer at all.
      expect(asked["rows"].map { |row| row["path"] }).to eq(%w[spec/models spec/jobs])
      expect(row_at(asked, "spec/models")).to include("baseline_count" => 1, "anchor_count" => 6, "change" => 5)
      expect(row_at(asked, "spec/jobs")).to include("baseline_count" => 0, "anchor_count" => 2, "new_area" => true)
      expect(asked).to include("directory_count" => 2, "baseline_recorded_count" => 1, "anchor_recorded_count" => 8)
    end

    # @intent: { entity: "directory_run_growth", action: "reconcile the area rollup with the layer mix", behavior: "uncapped, the sum of directory_run_growth change under ?layer=L equals layer_run_growth layers[L] change", layer: "request" }
    it "sums to the layer_run_growth change for the same layer" do
      %w[request unit].each do |layer|
        body = get_repository(query: { layer: layer })
        expect(body["directory_run_growth"]["truncated"]).to be(false)
        total = body["directory_run_growth"]["rows"].sum { |row| row["change"] }
        expect(total).to eq(body["layer_run_growth"]["layers"][layer]["change"]), layer
      end
    end

    # @intent: { entity: "directory_runtime_growth", action: "narrow the area time rollup to a layer", behavior: "?layer=request sums only the layer's duration_seconds per area and its totals are the layer's", layer: "request" }
    it "sums only the layer's time per area and reconciles with layer_runtime_growth" do
      body = get_repository(query: { layer: "request" })
      block = body["directory_runtime_growth"]

      expect(body["directory_runtime_growth_window"]).to include("state" => "comparable", "layer" => "request")
      expect(block["layer"]).to eq("request")
      expect(block).to include("directory_count" => 2, "baseline_recorded_count" => 1, "anchor_recorded_count" => 8,
                               "baseline_timed_count" => 1, "anchor_timed_count" => 8)
      expect(row_at(block, "spec/models")["baseline_seconds"]).to be_within(0.001).of(2.0)
      expect(row_at(block, "spec/models")["anchor_seconds"]).to be_within(0.001).of(18.0)
      expect(row_at(block, "spec/jobs")["anchor_seconds"]).to be_within(0.001).of(2.0)
      # A new area has no baseline sum (nil change); its anchor seconds are the whole movement.
      changed = block["rows"].sum { |row| row["anchor_seconds"].to_f - row["baseline_seconds"].to_f }
      expect(changed).to be_within(0.001).of(body["layer_runtime_growth"]["layers"]["request"]["change"])

      unasked = get_repository["directory_runtime_growth"]
      expect(unasked).not_to have_key("layer")
      expect(get_repository["directory_runtime_growth_window"]).not_to have_key("layer")
    end

    # @intent: { entity: "directory_run_file_growth", action: "narrow the file drill-ins to a layer", behavior: "?spec_directory=&layer=request narrows both file drill-ins to the layer and their area totals equal the layer-narrowed rollup row", layer: "request" }
    it "narrows both file drill-ins and equals the rollup row for the area" do
      body = get_repository(query: { spec_directory: "spec/models", layer: "request" })
      rollup = row_at(body["directory_run_growth"], "spec/models")
      files = body["directory_run_file_growth"]
      runtime_rollup = row_at(body["directory_runtime_growth"], "spec/models")
      runtime_files = body["directory_runtime_file_growth"]

      expect(files["layer"]).to eq("request")
      expect(runtime_files["layer"]).to eq("request")
      # request_1 held one example in both runs (unmoved, so last); no unit file appears.
      expect(files["rows"].map { |row| row["path"] }).to eq(%w[spec/models/request_2_spec.rb spec/models/request_3_spec.rb
                                                              spec/models/request_4_spec.rb spec/models/request_5_spec.rb
                                                              spec/models/request_6_spec.rb spec/models/request_1_spec.rb])
      expect(files["baseline_recorded_count"]).to eq(rollup["baseline_count"])
      expect(files["anchor_recorded_count"]).to eq(rollup["anchor_count"])
      expect(runtime_files).to include("baseline_recorded_count" => 1, "anchor_recorded_count" => 6,
                                       "baseline_timed_count" => 1, "anchor_timed_count" => 6)
      expect(runtime_files["rows"].sum { |row| row["anchor_seconds"].to_f })
        .to be_within(0.001).of(runtime_rollup["anchor_seconds"])
      expect(runtime_files["rows"].sum { |row| row["baseline_seconds"].to_f })
        .to be_within(0.001).of(runtime_rollup["baseline_seconds"])
      expect(body["directory_run_file_growth_window"]).to include("layer" => "request")
      expect(body["directory_runtime_file_growth_window"]).to include("layer" => "request")

      unasked = get_repository(query: { spec_directory: "spec/models" })
      expect(unasked["directory_run_file_growth"]).not_to have_key("layer")
      expect(unasked["directory_runtime_file_growth"]).not_to have_key("layer")
      expect(unasked["directory_run_file_growth"]["rows"].size).to eq(14)
    end

    # @intent: { entity: "directory_run_growth", action: "ignore unknown layers", behavior: "an unknown, blank or array layer is no ask: all four blocks are byte-identical to the unasked response", layer: "request" }
    it "reads malformed layer asks as no ask, across all four blocks" do
      keys = %w[directory_run_growth directory_runtime_growth directory_run_file_growth directory_runtime_file_growth
                directory_run_growth_window directory_runtime_growth_window directory_run_file_growth_window
                directory_runtime_file_growth_window]
      baseline = get_repository(query: { spec_directory: "spec/models" }).slice(*keys)
      expect(baseline["directory_run_file_growth"]).to be_present

      [{ layer: "bogus" }, { layer: "" }, { layer: ["request"] }].each do |extra|
        body = get_repository(query: { spec_directory: "spec/models" }.merge(extra)).slice(*keys)
        expect(body).to eq(baseline), extra.inspect
      end
    end

    # @intent: { entity: "directory_run_growth", action: "count the layer ask's queries", behavior: "asking for a layer adds no spec_observations statement over the unasked response", layer: "request" }
    it "issues the same number of spec_observations statements asked as unasked" do
      query = { spec_directory: "spec/models" }
      unasked = queries_against("spec_observations") { get_repository(query: query) }
      asked = queries_against("spec_observations") { get_repository(query: query.merge(layer: "request")) }

      expect(asked.size).to eq(unasked.size)
    end
  end

  describe "a layer the PREVIOUS run had no examples of" do
    before do
      two_runs(previous: [["spec/models", "unit", 4, 1.0]],
               latest: [["spec/models", "unit", 4, 1.0], ["spec/models", "request", 3, 2.0],
                        ["spec/jobs", "request", 2, 2.0]])
    end

    # @intent: { entity: "directory_run_growth", action: "compare a newly introduced layer", behavior: "a layer first appearing in the latest run is comparable with new areas, never previous_unrecorded", layer: "request" }
    it "is comparable with new areas for the count block" do
      body = get_repository(query: { layer: "request" })

      expect(body["directory_run_growth_window"]).to include("state" => "comparable", "comparable" => true,
                                                           "layer" => "request")
      rows = body["directory_run_growth"]["rows"]
      expect(rows.map { |row| [row["path"], row["new_area"], row["change"]] })
        .to eq([["spec/models", true, 3], ["spec/jobs", true, 2]])
      expect(body["directory_run_growth"]).to include("baseline_recorded_count" => 0, "anchor_recorded_count" => 5)
    end

    # @intent: { entity: "directory_runtime_growth", action: "compare a newly introduced layer", behavior: "a layer first appearing in the latest run is comparable with new areas, never previous_untimed", layer: "request" }
    it "is comparable with new areas for the runtime block" do
      body = get_repository(query: { layer: "request" })

      expect(body["directory_runtime_growth_window"]).to include("state" => "comparable", "layer" => "request")
      rows = body["directory_runtime_growth"]["rows"]
      expect(rows.map { |row| row["path"] }).to contain_exactly("spec/models", "spec/jobs")
      expect(rows.map { |row| row["new_area"] }).to all(be(true))
    end
  end

  describe "a layer the LATEST run no longer has" do
    before do
      two_runs(previous: [["spec/models", "unit", 4, 1.0], ["spec/models", "request", 3, 2.0]],
               latest: [["spec/models", "unit", 4, 1.0]])
    end

    # @intent: { entity: "directory_run_growth", action: "compare a removed layer", behavior: "a layer empty only in the latest run is comparable with removed areas", layer: "request" }
    it "reads the area as removed in both blocks" do
      body = get_repository(query: { layer: "request" })

      expect(body["directory_run_growth_window"]).to include("state" => "comparable")
      expect(row_at(body["directory_run_growth"], "spec/models")).to include("removed_area" => true, "change" => -3)
      expect(body["directory_runtime_growth_window"]).to include("state" => "comparable")
      expect(row_at(body["directory_runtime_growth"], "spec/models")).to include("removed_area" => true)
    end
  end

  describe "a layer neither run has examples of" do
    before do
      two_runs(previous: [["spec/models", "unit", 4, 1.0]], latest: [["spec/models", "unit", 5, 1.0]])
    end

    # @intent: { entity: "directory_run_growth", action: "answer a layer empty in both runs", behavior: "comparable with zero rows and directory_count 0 in both blocks, not neither_recorded or neither_timed", layer: "system" }
    it "is the defined comparable-but-empty answer for count and runtime" do
      body = get_repository(query: { layer: "system", spec_directory: "spec/models" })

      expect(body["directory_run_growth_window"]).to include("state" => "comparable", "layer" => "system")
      expect(body["directory_run_growth"]).to include("rows" => [], "directory_count" => 0, "truncated" => false,
                                                    "layer" => "system")
      expect(body["directory_runtime_growth_window"]).to include("state" => "comparable")
      expect(body["directory_runtime_growth"]).to include("rows" => [], "directory_count" => 0, "layer" => "system")
      expect(body["directory_run_file_growth"]).to include("rows" => [], "file_count" => 0)
      expect(body["directory_runtime_file_growth"]).to include("rows" => [], "file_count" => 0)
    end
  end

  describe "a run that recorded no per-example detail" do
    # @intent: { entity: "directory_run_growth", action: "keep the unrecorded refusal under a layer", behavior: "a previous run with no per-example rows still reads previous_unrecorded when a layer is asked", layer: "request" }
    it "keeps the unrecorded states at run grain" do
      ingest([], commit_sha: "previous0001", at: 20.days.ago, total: 5)
      ingest(examples([["spec/models", "request", 2, 1.0]]), commit_sha: "latest000001", at: 10.days.ago)

      body = get_repository(query: { layer: "request" })
      expect(body["directory_run_growth_window"]).to include("state" => "previous_unrecorded", "layer" => "request")
      expect(body["directory_run_growth"]).to be_nil
      expect(body["directory_runtime_growth_window"]).to include("state" => "previous_unrecorded")
    end
  end

  describe "a layer whose examples were not timed" do
    # @intent: { entity: "directory_runtime_growth", action: "refuse an untimed layer", behavior: "previous_untimed fires only when the previous run HAS examples of the layer and none were timed", layer: "request" }
    it "reads previous_untimed only where that side has the layer's examples" do
      two_runs(previous: [["spec/models", "request", 2, nil], ["spec/models", "unit", 2, 1.0]],
               latest: [["spec/models", "request", 3, 1.0], ["spec/models", "unit", 2, 1.0]])

      asked = get_repository(query: { layer: "request" })
      expect(asked["directory_runtime_growth_window"]).to include("state" => "previous_untimed")
      expect(asked["directory_runtime_growth"]).to be_nil
      expect(get_repository(query: { layer: "unit" })["directory_runtime_growth_window"])
        .to include("state" => "comparable")
    end
  end
end
