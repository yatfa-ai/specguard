# frozen_string_literal: true

require "rails_helper"

# `?layer=` on `GET /api/v1/repository` also ranks `latest_run.spec_files` ("Heaviest spec files") by
# ONE declared layer's time (SPGD-1758). "request holds most of the machine time" (`layer_durations`)
# then has a route to WHICH FILES. The layer is what each example's `@intent` declared, never inferred
# from the path, and it rides into the query BEFORE the LIMIT — a file below the unasked top ten cannot
# be recovered by a client holding that top ten.
#
# The fixture's job is the disagreement: ten unit files at 5s each fill the unasked top ten, while
# `spec/models/slow_requests_spec.rb` holds 5 request examples at 0.9s (4.5s) — the request layer's
# heaviest file, yet below every unit file and so absent from the unasked top ten.
RSpec.describe "GET /api/v1/repository — ?layer= on spec_files", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def latest_run(query: {}) = get_repository(query: query)["latest_run"]

  def spec_files(query: {}) = latest_run(query: query)["spec_files"]

  # `api_key.last_used_at` is stamped per request at one-second resolution; it describes the credential
  # and not the ask, so it is the one key dropped before bodies are compared.
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
    test_run = create_test_run(repository: repository, commit_sha: "filelayer001", branch: "main",
                               total_specs_count: 30, duration_seconds: 90.0)
    # Ten unit files at 5s: the unasked top ten is these and only these.
    10.times { |i| observe(test_run, path: format("spec/unit/u%02d_spec.rb", i), line: 1, duration: 5.0, layer: "unit") }
    # File A: five cheap request examples, 4.5s in all — below the ten 5s unit files.
    5.times { |i| observe(test_run, path: "spec/models/slow_requests_spec.rb", line: i + 1, duration: 0.9, layer: "request") }
    # Another request file that TIES with A on layer time (4.5s, one example untimed): path breaks the tie.
    observe(test_run, path: "spec/requests/b_spec.rb", line: 1, duration: 4.5, layer: "request")
    observe(test_run, path: "spec/requests/b_spec.rb", line: 2, duration: nil, layer: "request")
    # One integration file and an undeclared file living under spec/requests/ — the path decides nothing.
    observe(test_run, path: "spec/integration/i_spec.rb", line: 1, duration: 2.0, layer: "integration")
    observe(test_run, path: "spec/requests/login_spec.rb", line: 1, duration: 3.0, layer: nil)
    test_run
  end

  let(:unasked) { get_repository }

  # AC1: THE REGRESSION THE FEATURE EXISTS FOR. The request-heavy file is NOT in the default top ten
  # (limit default) and IS rank one under ?layer=request.
  # @intent: { entity: "Spec files rollup", action: "rank by a declared layer", behavior: "layer=request ranks files by request-layer time and surfaces a file the unasked default top ten cannot show, with the asked layer echoed and the limit unchanged", layer: "request" }
  it "ranks by the layer's time and surfaces a file the unasked top ten drops" do
    unasked_paths = spec_files["rows"].map { it["path"] }
    expect(unasked_paths.size).to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
    expect(unasked_paths).not_to include("spec/models/slow_requests_spec.rb")

    block = spec_files(query: { layer: "request" })

    expect(block["rows"].map { it["path"] }).to eq(%w[spec/models/slow_requests_spec.rb spec/requests/b_spec.rb])
    expect(block["rows"].map { it["total_seconds"] }).to eq([4.5, 4.5])
    expect(block["layer"]).to eq("request")
    expect(block["limit"]).to eq(SpecObservation::HEAVIEST_FILES_LIMIT)
  end

  # AC2: each row's counts are the file's examples IN THE LAYER; file_count is the layer's file count;
  # layer_counts is non-zero only for the asked layer.
  # @intent: { entity: "Spec files rollup", action: "count within a declared layer", behavior: "under a layer each row's recorded and timed counts are the file's examples in that layer, file_count is the number of files holding the layer, and layer_counts is non-zero only for that layer", layer: "request" }
  it "counts the layer's own population per file" do
    block = spec_files(query: { layer: "request" })
    rows = block["rows"].to_h { [it["path"], it] }

    expect(rows.fetch("spec/models/slow_requests_spec.rb"))
      .to include("recorded_count" => 5, "timed_count" => 5,
                  "layer_counts" => { "unit" => 0, "integration" => 0, "request" => 5, "system" => 0, "undeclared" => 0 })
    expect(rows.fetch("spec/requests/b_spec.rb"))
      .to include("total_seconds" => 4.5, "recorded_count" => 2, "timed_count" => 1,
                  "layer_counts" => { "unit" => 0, "integration" => 0, "request" => 2, "system" => 0, "undeclared" => 0 })
    expect(block["file_count"]).to eq(2)
    expect(block["file_count"]).to eq(run.spec_observations.where(intent_layer: "request").distinct.count(:spec_file_path))
    expect(block["rows"].sum { it["recorded_count"] }).to eq(latest_run["layer_counts"]["request"])
  end

  # @intent: { entity: "Spec files rollup", action: "select the undeclared layer", behavior: "layer=undeclared selects intent_layer IS NULL rows, so an undeclared file under spec/requests is undeclared and a request-declared file under spec/models is a request", layer: "request" }
  it "decides the layer by the stored declaration, never the path" do
    undeclared = spec_files(query: { layer: "undeclared" })
    expect(undeclared["rows"].map { it["path"] }).to eq(["spec/requests/login_spec.rb"])
    expect(undeclared["layer"]).to eq("undeclared")

    expect(spec_files(query: { layer: "request" })["rows"].map { it["path"] })
      .not_to include("spec/requests/login_spec.rb")
    expect(spec_files(query: { layer: "request" })["rows"].map { it["path"] }).to include("spec/models/slow_requests_spec.rb")
  end

  # @intent: { entity: "Spec files rollup", action: "ignore unknown layers", behavior: "an unknown, array, NUL or blank layer is no ask and serves a body deep-equal to the unasked one with no layer key", layer: "request" }
  it "reads every malformed or unknown ask as no ask, body identical to unasked" do
    baseline = unasked.except("api_key")

    ["?layer=bogus", "?layer[]=request", "?layer[a]=request", "?layer=%00", "?layer=", "?layer=REQUEST"].each do |suffix|
      body = raw_get("/api/v1/repository#{suffix}")

      expect(response).to have_http_status(:ok), suffix
      expect(body).to eq(baseline), suffix
    end
    expect(baseline["latest_run"]["spec_files"].keys).to contain_exactly("rows", "file_count", "limit")
  end

  # @intent: { entity: "Spec files rollup", action: "keep the recorded gate run-level", behavior: "a layer no file declared serves a present block with empty rows and file_count 0, while a run that recorded nothing stays null with or without the ask", layer: "request" }
  it "serves an empty block, not null, for a layer nobody declared; null stays a run-level fact" do
    expect(spec_files(query: { layer: "system" }))
      .to eq("rows" => [], "file_count" => 0, "limit" => SpecObservation::HEAVIEST_FILES_LIMIT, "layer" => "system")

    bare = create_test_run(repository: repository, commit_sha: "filelayer002", branch: "main",
                           total_specs_count: 5, duration_seconds: 1.0, created_at: 1.hour.from_now)
    expect(bare.spec_observations).to be_empty
    expect(latest_run).to have_key("spec_files")
    expect(spec_files).to be_nil
    expect(spec_files(query: { layer: "request" })).to be_nil
  end

  # AC: panel and API agree row for row for a given layer.
  # @intent: { entity: "Spec files rollup", action: "mirror the show rows under a layer", behavior: "spec_files rows under a layer match the presenter repositories#show assigns row for row and in the same order", layer: "request" }
  it "serves the same rows, in the same order, the dashboard presenter ranks under the layer" do
    shown = SpecFileDurations.for(repository.latest_test_run, layer: "request")
    block = spec_files(query: { layer: "request" })

    expect(block["rows"].map { it["path"] }).to eq(shown.rows.map(&:path))
    expect(block["rows"].map { it["total_seconds"] }).to eq(shown.rows.map(&:total_seconds))
    expect(block["rows"].map { it["recorded_count"] }).to eq(shown.rows.map(&:recorded_count))
    expect(block["rows"].map { it["timed_count"] }).to eq(shown.rows.map(&:timed_count))
    expect(block["file_count"]).to eq(shown.file_count)
  end

  # Composes with ?limit= unchanged: the limit is echoed as applied and truncation is detectable
  # against the LAYER's file count.
  # @intent: { entity: "Spec files rollup", action: "compose layer with limit", behavior: "layer composes with limit, the applied limit is echoed and file_count is the layer's file count so truncation is detectable", layer: "request" }
  it "composes with ?limit=" do
    block = spec_files(query: { layer: "request", limit: 1 })

    expect(block["rows"].map { it["path"] }).to eq(["spec/models/slow_requests_spec.rb"])
    expect(block["limit"]).to eq(1)
    expect(block["file_count"]).to eq(2)
  end

  describe "what the layer ask costs" do
    # @intent: { entity: "Repository latest-run endpoint", action: "read the by-file grain once", behavior: "an asked layer issues one grouped by-file statement carrying the layer predicate, exactly as many per-file reads as the unasked request", layer: "request" }
    it "keeps the rollup to one grouped statement, asked or not" do
      by_file = ->(sqls) { sqls.select { it.include?("GROUP BY \"spec_observations\".\"spec_file_path\"") && !it.include?("directory") } }
      unasked_reads = by_file.(queries_against("spec_observations") { get_repository })
      asked_reads = by_file.(queries_against("spec_observations") { get_repository(query: { layer: "request" }) })

      expect(unasked_reads.size).to eq(1)
      expect(asked_reads.size).to eq(1)
      expect(asked_reads.first).to match(/WHERE .*intent_layer/m)
    end
  end
end
