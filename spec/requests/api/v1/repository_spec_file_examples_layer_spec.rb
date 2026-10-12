# frozen_string_literal: true

require "rails_helper"

# `?layer=` on `GET /api/v1/repository` also narrows the `latest_run.spec_file_examples` drill-in
# (SPGD-1770) to ONE declared layer, so a file opened out of the layer-ranked `spec_files` row holds the
# rows that row counted. The layer is what each example's `@intent` declared, never inferred from the
# path. `layer` is echoed only when asked, so every unasked and malformed body stays key-for-key what it
# was.
RSpec.describe "GET /api/v1/repository — ?layer= on spec_file_examples", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }
  let(:file) { "spec/models/mixed_spec.rb" }

  def get_repository(query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def latest_run(query: {}) = get_repository(query: query)["latest_run"]

  def block(query: {}) = latest_run(query: { spec_file: file }.merge(query))["spec_file_examples"]

  def observe(run, line:, duration:, layer:, path: file)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "example #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "filelayerapi1", branch: "main",
                               total_specs_count: 40, duration_seconds: 90.0)
    3.times { |i| observe(test_run, line: i + 1, duration: 3.0, layer: "request") }
    2.times { |i| observe(test_run, line: 10 + i, duration: nil, layer: "request") }
    20.times { |i| observe(test_run, line: 100 + i, duration: 5.0, layer: "unit") }
    2.times { |i| observe(test_run, line: 200 + i, duration: 1.0, layer: nil, path: "spec/requests/plain_spec.rb") }
    test_run
  end

  # @intent: { entity: "Spec file examples drill-in", action: "open a file within a declared layer", behavior: "layer=request lists exactly the file's five request rows and echoes the layer, where the unasked block lists all twenty-five with no layer key", layer: "request" }
  it "narrows the file to the layer and echoes it only when asked" do
    unasked = block
    expect(unasked["rows"].size).to eq(25)
    expect(unasked).not_to have_key("layer")
    expect(unasked.keys).to contain_exactly("path", "rows", "recorded_count", "timed_count", "limit")

    asked = block(query: { layer: "request" })
    expect(asked["rows"].size).to eq(5)
    expect(asked["rows"].map { it["intent_layer"] }.uniq).to eq(["request"])
    expect(asked).to include("layer" => "request", "recorded_count" => 5, "timed_count" => 3, "path" => file)
    expect(asked["limit"]).to eq(SpecObservation::FILE_EXAMPLES_LIMIT)

    expect(block(query: { layer: "unit" })["rows"].size).to eq(20)
  end

  # @intent: { entity: "Spec file examples drill-in", action: "open a file within a declared layer", behavior: "the opened file's recorded and timed counts equal the layer-ranked spec_files row for the same file", layer: "request" }
  it "serves the counts the clicked spec_files row states" do
    row = latest_run(query: { layer: "request" })["spec_files"]["rows"].find { it["path"] == file }
    asked = block(query: { layer: "request" })

    expect(asked["recorded_count"]).to eq(row["recorded_count"])
    expect(asked["timed_count"]).to eq(row["timed_count"])
  end

  # @intent: { entity: "Spec file examples drill-in", action: "select the undeclared layer", behavior: "layer=undeclared selects intent_layer NULL rows, so rows under spec/requests are undeclared and the request layer does not see them", layer: "request" }
  it "decides the layer by the stored declaration, never the path" do
    path = "spec/requests/plain_spec.rb"
    undeclared = latest_run(query: { spec_file: path, layer: "undeclared" })["spec_file_examples"]
    request = latest_run(query: { spec_file: path, layer: "request" })["spec_file_examples"]

    expect(undeclared["rows"].size).to eq(2)
    expect(request).to include("rows" => [], "layer" => "request", "path" => path)
  end

  # @intent: { entity: "Spec file examples drill-in", action: "state an empty layer in a recorded file", behavior: "a layer nothing in a recorded file declared serves the block with empty rows, zero counts and the layer echoed, never null", layer: "system" }
  it "serves an empty block, not null, for a layer nobody declared in the file" do
    empty = block(query: { layer: "system" })

    expect(empty).to include("rows" => [], "recorded_count" => 0, "timed_count" => 0, "layer" => "system", "path" => file)
  end

  # @intent: { entity: "Spec file examples drill-in", action: "ignore unknown layers", behavior: "an unknown, array, NUL or blank layer is no ask and serves a body deep-equal to the unasked one with no layer key", layer: "request" }
  it "reads every malformed or unknown ask as no ask, body identical to unasked" do
    path = "/api/v1/repository?spec_file=#{CGI.escape(file)}"
    get path, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }
    baseline = response.parsed_body.except("api_key")

    ["layer=bogus", "layer[]=request", "layer[a]=request", "layer=%00", "layer=", "layer=REQUEST"].each do |query|
      get "#{path}&#{query}", headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

      expect(response).to have_http_status(:ok), query
      expect(response.parsed_body.except("api_key")).to eq(baseline), query
    end
    expect(baseline["latest_run"]["spec_file_examples"]).not_to have_key("layer")
  end

  # @intent: { entity: "Spec file examples drill-in", action: "serve the panel's rows", behavior: "the block under a layer lists the same examples as the presenter repositories#show assigns, in order", layer: "request" }
  it "serves the same rows the dashboard presenter ranks under the layer" do
    shown = SpecFileExamples.for(repository.latest_test_run, file, layer: "request")

    expect(block(query: { layer: "request" })["rows"].map { it["line_number"] }).to eq(shown.rows.map(&:line_number))
  end

  describe "what the layer ask costs" do
    # @intent: { entity: "Repository latest-run endpoint", action: "read the one-file grain", behavior: "an asked non-empty layer issues the same single file statement as the unasked request, carrying the layer predicate, with no existence read", layer: "request" }
    it "keeps the single file statement, asked or not" do
      file_reads = ->(sqls) { sqls.select { it.include?("file_recorded_count") } }
      unasked = queries_against("spec_observations") { get_repository(query: { spec_file: file }) }
      asked = queries_against("spec_observations") { get_repository(query: { spec_file: file, layer: "request" }) }

      expect(file_reads.(unasked).size).to eq(1)
      expect(file_reads.(asked).size).to eq(1)
      expect(file_reads.(asked).first).to match(/WHERE .*intent_layer/m)
      expect(file_reads.(unasked).first).not_to match(/WHERE[^(]*intent_layer/m)
      expect(asked.size).to eq(unasked.size)
    end
  end
end
