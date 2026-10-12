# frozen_string_literal: true

require "rails_helper"

# `?layer=` on `GET /api/v1/repository` also narrows the `latest_run.spec_directory_files` drill-in
# (SPGD-1776) to ONE declared layer, so an area opened out of the layer-ranked `spec_directories` row
# holds the rows that row counted. The layer is what each example's `@intent` declared, never inferred
# from the path. `layer` is echoed only when asked, so every unasked and malformed body stays key-for-key
# what it was.
RSpec.describe "GET /api/v1/repository — ?layer= on spec_directory_files", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }
  let(:area) { "spec/models" }

  def get_repository(query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def latest_run(query: {}) = get_repository(query: query)["latest_run"]

  def block(query: {}) = latest_run(query: { spec_directory: area }.merge(query))["spec_directory_files"]

  def observe(run, path:, line:, duration:, layer:)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "dirlayerapi01", branch: "main",
                               total_specs_count: 40, duration_seconds: 90.0)
    # a_spec: 2 request (one untimed) + 2 unit; b_spec: 1 request; c_spec: unit only; d_spec: undeclared.
    observe(test_run, path: "spec/models/a_spec.rb", line: 1, duration: 3.0, layer: "request")
    observe(test_run, path: "spec/models/a_spec.rb", line: 2, duration: nil, layer: "request")
    2.times { |i| observe(test_run, path: "spec/models/a_spec.rb", line: 10 + i, duration: 20.0, layer: "unit") }
    observe(test_run, path: "spec/models/b_spec.rb", line: 1, duration: 4.0, layer: "request")
    observe(test_run, path: "spec/models/c_spec.rb", line: 1, duration: 30.0, layer: "unit")
    observe(test_run, path: "spec/models/d_spec.rb", line: 1, duration: 1.0, layer: nil)
    test_run
  end

  # @intent: { entity: "Spec directory files drill-in", action: "open an area within a declared layer", behavior: "layer=request lists only the files with a request example, ranked by request time, with the layer's per-file counts and the layer echoed, where the unasked block lists every file with no layer key", layer: "request" }
  it "narrows the area to the layer, ranks by the layer's time and echoes it only when asked" do
    unasked = block
    expect(unasked["rows"].map { it["path"] }.first(2)).to eq(%w[spec/models/a_spec.rb spec/models/c_spec.rb])
    expect(unasked["rows"].size).to eq(4)
    expect(unasked).not_to have_key("layer")

    asked = block(query: { layer: "request" })
    expect(asked["rows"].map { it["path"] }).to eq(%w[spec/models/b_spec.rb spec/models/a_spec.rb])
    expect(asked["layer"]).to eq("request")
    a_row = asked["rows"].find { it["path"].end_with?("a_spec.rb") }
    expect(a_row).to include("recorded_count" => 2, "timed_count" => 1, "total_seconds" => 3.0)
    expect(a_row["layer_counts"]).to include("request" => 2, "unit" => 0)
    expect(asked["limit"]).to eq(SpecObservation::SPEC_DIRECTORY_FILES_LIMIT)
  end

  # @intent: { entity: "Spec directory files drill-in", action: "open an area within a declared layer", behavior: "the opened area's recorded, timed, file and layer counts equal the layer-ranked spec_directories row for the same area", layer: "request" }
  it "serves the counts the clicked spec_directories row states" do
    row = latest_run(query: { layer: "request" })["spec_directories"]["rows"].find { it["path"] == area }
    asked = block(query: { layer: "request" })

    expect(asked["recorded_count"]).to eq(row["recorded_count"])
    expect(asked["timed_count"]).to eq(row["timed_count"])
    expect(asked["file_count"]).to eq(2)
    expect(asked["layer_counts"]).to eq(row["layer_counts"])
  end

  # @intent: { entity: "Spec directory files drill-in", action: "select the undeclared layer", behavior: "layer=undeclared selects intent_layer NULL rows regardless of path, so an area under spec/requests that declared nothing is undeclared and the request layer does not see it", layer: "request" }
  it "decides the layer by the stored declaration, never the path" do
    observe(run, path: "spec/requests/plain_spec.rb", line: 1, duration: 1.0, layer: nil)
    query = { spec_directory: "spec/requests" }
    undeclared = latest_run(query: query.merge(layer: "undeclared"))["spec_directory_files"]
    request = latest_run(query: query.merge(layer: "request"))["spec_directory_files"]

    expect(undeclared["rows"].map { it["path"] }).to eq(["spec/requests/plain_spec.rb"])
    expect(request).to include("rows" => [], "layer" => "request", "path" => "spec/requests", "recorded_count" => 0)
  end

  # @intent: { entity: "Spec directory files drill-in", action: "state an empty layer in a recorded area", behavior: "a layer nothing in a recorded area declared serves the block with empty rows, zero counts and the layer echoed, never null", layer: "system" }
  it "serves an empty block, not null, for a layer nobody declared in the area" do
    expect(block(query: { layer: "system" })).to include("rows" => [], "file_count" => 0, "recorded_count" => 0,
                                                           "timed_count" => 0, "layer" => "system", "path" => area)
  end

  # @intent: { entity: "Spec directory files drill-in", action: "ignore unknown layers", behavior: "an unknown, array, NUL or blank layer is no ask and serves a body deep-equal to the unasked one with no layer key", layer: "request" }
  it "reads every malformed or unknown ask as no ask, body identical to unasked" do
    path = "/api/v1/repository?spec_directory=#{CGI.escape(area)}"
    get path, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }
    baseline = response.parsed_body.except("api_key")

    ["layer=bogus", "layer[]=request", "layer[a]=request", "layer=%00", "layer=", "layer=REQUEST"].each do |query|
      get "#{path}&#{query}", headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

      expect(response).to have_http_status(:ok), query
      expect(response.parsed_body.except("api_key")).to eq(baseline), query
    end
    expect(baseline["latest_run"]["spec_directory_files"]).not_to have_key("layer")
  end

  describe "what the layer ask costs" do
    # @intent: { entity: "Repository latest-run endpoint", action: "read the one-area grain", behavior: "an asked non-empty layer issues the same single area statement as the unasked request, carrying the layer predicate, with no existence read, and the empty-layer ask adds exactly one", layer: "request" }
    it "keeps the single area statement, asked or not, and adds one existence read only when empty" do
      area_reads = ->(sqls) { sqls.select { it.include?("OVER ()") && it.include?("GROUP BY") && !it.include?("DISTINCT") } }
      unasked = queries_against("spec_observations") { get_repository(query: { spec_directory: area }) }
      asked = queries_against("spec_observations") { get_repository(query: { spec_directory: area, layer: "request" }) }
      empty = queries_against("spec_observations") { get_repository(query: { spec_directory: area, layer: "system" }) }

      expect(asked.size).to eq(unasked.size)
      expect(area_reads.(asked).size).to eq(area_reads.(unasked).size)
      expect(empty.size).to eq(unasked.size + 1)
    end
  end
end
