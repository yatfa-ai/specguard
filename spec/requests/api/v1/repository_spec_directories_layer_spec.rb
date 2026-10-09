# frozen_string_literal: true

require "rails_helper"

# `?layer=` on `GET /api/v1/repository` also ranks `latest_run.spec_directories` ("Heaviest spec
# directories") by ONE declared layer's time (SPGD-1761). "request holds most of the machine time"
# (`layer_durations`) then has a route to WHICH AREAS. The layer is what each example's `@intent`
# declared, never inferred from the path, and it rides into the query BEFORE the LIMIT — an area below
# the unasked top ten cannot be recovered by a client holding that top ten.
#
# The fixture's job is the disagreement: ten unit areas at 5s each fill the unasked top ten, while
# `spec/slow_requests` holds 5 request examples at 0.9s (4.5s) — the request layer's heaviest area, yet
# below every unit area and so absent from the unasked top ten.
RSpec.describe "GET /api/v1/repository — ?layer= on spec_directories", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def latest_run(query: {}) = get_repository(query: query)["latest_run"]

  def spec_directories(query: {}) = latest_run(query: query)["spec_directories"]

  # `api_key.last_used_at` describes the credential and not the ask, so it is the one key dropped
  # before bodies are compared.
  def raw_get(path)
    get path, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }
    response.parsed_body.except("api_key")
  end

  def observe(run, path:, line:, duration:, layer:)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "dirlayer0001", branch: "main",
                               total_specs_count: 30, duration_seconds: 90.0)
    # Ten unit areas at 5s: the unasked top ten is these and only these.
    10.times { |i| observe(test_run, path: format("spec/unit%02d/a_spec.rb", i), line: 1, duration: 5.0, layer: "unit") }
    # Area A: five cheap request examples, 4.5s in all — below every 5s unit area.
    5.times { |i| observe(test_run, path: "spec/slow_requests/a_spec.rb", line: i + 1, duration: 0.9, layer: "request") }
    # Another request area that TIES with A on layer time (4.5s, one example untimed): path breaks the tie.
    observe(test_run, path: "spec/zz_requests/b_spec.rb", line: 1, duration: 4.5, layer: "request")
    observe(test_run, path: "spec/zz_requests/b_spec.rb", line: 2, duration: nil, layer: "request")
    observe(test_run, path: "spec/integration/i_spec.rb", line: 1, duration: 2.0, layer: "integration")
    # Declares nothing, but lives under spec/requests/: the path decides nothing.
    observe(test_run, path: "spec/requests/login_spec.rb", line: 1, duration: 3.0, layer: nil)
    test_run
  end

  # THE REGRESSION THE FEATURE EXISTS FOR: the request-heavy area is NOT in the default top ten and IS
  # rank one under ?layer=request.
  # @intent: { entity: "Spec directories rollup", action: "rank by a declared layer", behavior: "layer=request ranks areas by request-layer time and surfaces an area the unasked default top ten cannot show, with the asked layer echoed and the limit unchanged", layer: "request" }
  it "ranks by the layer's time and surfaces an area the unasked top ten drops" do
    unasked_paths = spec_directories["rows"].map { it["path"] }
    expect(unasked_paths.size).to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
    expect(unasked_paths).not_to include("spec/slow_requests")

    block = spec_directories(query: { layer: "request" })

    expect(block["rows"].map { it["path"] }).to eq(%w[spec/slow_requests spec/zz_requests])
    expect(block["rows"].map { it["total_seconds"] }).to eq([4.5, 4.5])
    expect(block["layer"]).to eq("request")
    expect(block["limit"]).to eq(SpecObservation::HEAVIEST_DIRECTORIES_LIMIT)
  end

  # @intent: { entity: "Spec directories rollup", action: "count within a declared layer", behavior: "under a layer each row's recorded and timed counts are the area's examples in that layer, directory_count is the number of areas holding the layer, and layer_counts is non-zero only for that layer", layer: "request" }
  it "counts the layer's own population per area" do
    block = spec_directories(query: { layer: "request" })
    rows = block["rows"].to_h { [it["path"], it] }

    expect(rows.fetch("spec/slow_requests"))
      .to include("recorded_count" => 5, "timed_count" => 5,
                  "layer_counts" => { "unit" => 0, "integration" => 0, "request" => 5, "system" => 0, "undeclared" => 0 })
    expect(rows.fetch("spec/zz_requests"))
      .to include("total_seconds" => 4.5, "recorded_count" => 2, "timed_count" => 1,
                  "layer_counts" => { "unit" => 0, "integration" => 0, "request" => 2, "system" => 0, "undeclared" => 0 })
    expect(block["directory_count"]).to eq(2)
    expect(block["directory_count"])
      .to eq(run.spec_observations.where(intent_layer: "request").distinct.count(:spec_file_path))
    expect(block["rows"].sum { it["recorded_count"] }).to eq(latest_run["layer_counts"]["request"])
  end

  # @intent: { entity: "Spec directories rollup", action: "select the undeclared layer", behavior: "layer=undeclared selects intent_layer IS NULL rows, so an undeclared area under spec/requests is undeclared and a request-declared area under spec/slow_requests is a request", layer: "request" }
  it "decides the layer by the stored declaration, never the path" do
    undeclared = spec_directories(query: { layer: "undeclared" })
    expect(undeclared["rows"].map { it["path"] }).to eq(["spec/requests"])
    expect(undeclared["layer"]).to eq("undeclared")

    request_paths = spec_directories(query: { layer: "request" })["rows"].map { it["path"] }
    expect(request_paths).not_to include("spec/requests")
    expect(request_paths).to include("spec/slow_requests")
  end

  # @intent: { entity: "Spec directories rollup", action: "ignore unknown layers", behavior: "an unknown, array, NUL or blank layer is no ask and serves a body deep-equal to the unasked one with no layer key", layer: "request" }
  it "reads every malformed or unknown ask as no ask, body identical to unasked" do
    baseline = get_repository.except("api_key")

    ["?layer=bogus", "?layer[]=request", "?layer[a]=request", "?layer=%00", "?layer=", "?layer=REQUEST"].each do |suffix|
      body = raw_get("/api/v1/repository#{suffix}")

      expect(response).to have_http_status(:ok), suffix
      expect(body).to eq(baseline), suffix
    end
    expect(baseline["latest_run"]["spec_directories"].keys).to contain_exactly("rows", "directory_count", "limit")
  end

  # @intent: { entity: "Spec directories rollup", action: "keep the recorded gate run-level", behavior: "a layer no area declared serves a present block with empty rows and directory_count 0, while a run that recorded nothing stays null with or without the ask", layer: "request" }
  it "serves an empty block, not null, for a layer nobody declared; null stays a run-level fact" do
    expect(spec_directories(query: { layer: "system" }))
      .to eq("rows" => [], "directory_count" => 0, "limit" => SpecObservation::HEAVIEST_DIRECTORIES_LIMIT,
             "layer" => "system")

    bare = create_test_run(repository: repository, commit_sha: "dirlayer0002", branch: "main",
                           total_specs_count: 5, duration_seconds: 1.0, created_at: 1.hour.from_now)
    expect(bare.spec_observations).to be_empty
    expect(latest_run).to have_key("spec_directories")
    expect(spec_directories).to be_nil
    expect(spec_directories(query: { layer: "request" })).to be_nil
  end

  # Panel and API agree row for row for a given layer.
  # @intent: { entity: "Spec directories rollup", action: "mirror the show rows under a layer", behavior: "spec_directories rows under a layer match the presenter repositories#show assigns row for row and in the same order", layer: "request" }
  it "serves the same rows, in the same order, the dashboard presenter ranks under the layer" do
    shown = SpecDirectoryDurations.for(repository.latest_test_run, layer: "request")
    block = spec_directories(query: { layer: "request" })

    expect(block["rows"].map { it["path"] }).to eq(shown.rows.map(&:path))
    expect(block["rows"].map { it["total_seconds"] }).to eq(shown.rows.map(&:total_seconds))
    expect(block["rows"].map { it["recorded_count"] }).to eq(shown.rows.map(&:recorded_count))
    expect(block["rows"].map { it["timed_count"] }).to eq(shown.rows.map(&:timed_count))
    expect(block["rows"].map { it["layer_counts"] }).to eq(shown.rows.map { it.layer_counts.stringify_keys })
    expect(block["directory_count"]).to eq(shown.directory_count)
  end

  # @intent: { entity: "Spec directories rollup", action: "compose layer with limit", behavior: "layer composes with limit, the applied limit is echoed and directory_count is the layer's area count so truncation is detectable", layer: "request" }
  it "composes with ?limit=" do
    block = spec_directories(query: { layer: "request", limit: 1 })

    expect(block["rows"].map { it["path"] }).to eq(["spec/slow_requests"])
    expect(block["limit"]).to eq(1)
    expect(block["directory_count"]).to eq(2)
  end

  describe "what the layer ask costs" do
    # @intent: { entity: "Repository latest-run endpoint", action: "read the by-directory grain once", behavior: "an asked layer issues one grouped by-directory statement carrying the layer predicate, exactly as many per-directory reads as the unasked request", layer: "request" }
    it "keeps the rollup to one grouped statement, asked or not" do
      # The by-directory aggregate is the only statement carrying the window count over the run's rows.
      by_directory = ->(sqls) { sqls.select { it.include?("COUNT(*) OVER ()") && it.include?("COUNT(DISTINCT name)") && !it.include?("spec_directory") } }
      unasked_reads = by_directory.(queries_against("spec_observations") { get_repository })
      asked_reads = by_directory.(queries_against("spec_observations") { get_repository(query: { layer: "request" }) })

      expect(unasked_reads.size).to eq(1)
      expect(asked_reads.size).to eq(1)
      expect(asked_reads.first).to match(/WHERE .*intent_layer/m)
    end
  end
end
