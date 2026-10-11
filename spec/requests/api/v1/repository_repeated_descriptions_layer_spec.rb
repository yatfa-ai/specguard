# frozen_string_literal: true

require "rails_helper"

# `?layer=` on `GET /api/v1/repository` also finds `latest_run.repeated_descriptions` ("Descriptions this
# run recorded more than once") WITHIN ONE declared layer (SPGD-1763), and narrows the
# `repeated_description_examples` drill-in the same way. The layer is what each example's `@intent`
# declared, never inferred from the path, and rides into the query BEFORE the grouping and the LIMIT.
#
# The fixture's job is the disagreement: ten unit descriptions repeated twice at 7s (14s each) fill the
# unasked top ten, while "A request loop" is repeated four times at 3s (12s) — it ranks 11th unasked and
# first under `?layer=request`.
RSpec.describe "GET /api/v1/repository — ?layer= on repeated_descriptions", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  def get_repository(query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def latest_run(query: {}) = get_repository(query: query)["latest_run"]

  def repeated(query: {}) = latest_run(query: query)["repeated_descriptions"]

  def examples(query: {}) = latest_run(query: query)["repeated_description_examples"]

  def raw_get(path)
    get path, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }
    response.parsed_body.except("api_key")
  end

  def observe(run, name:, line:, duration:, layer:, path: "spec/models/a_spec.rb")
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: name,
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "desclayer001", branch: "main",
                               total_specs_count: 40, duration_seconds: 90.0)
    line = 0
    # Ten unit descriptions at 2 x 7s = 14s each: the unasked top ten is these and only these.
    10.times { |g| 2.times { observe(test_run, name: "unit group #{g}", line: (line += 1), duration: 7.0, layer: "unit") } }
    # A: four request examples at 3s = 12s — 11th unasked, rank one under request.
    4.times { observe(test_run, name: "A request loop", line: (line += 1), duration: 3.0, layer: "request") }
    # One request + one unit example: repeated across layers, within neither.
    observe(test_run, name: "straddle", line: (line += 1), duration: 1.0, layer: "request")
    observe(test_run, name: "straddle", line: (line += 1), duration: 1.0, layer: "unit")
    # Undeclared pair under a request-looking path: the path decides nothing.
    2.times { observe(test_run, name: "plain pair", line: (line += 1), duration: 0.5, layer: nil, path: "spec/requests/login_spec.rb") }
    # An unnamed request example.
    observe(test_run, name: nil, line: (line += 1), duration: 1.0, layer: "request")
    test_run
  end

  let(:unasked) { get_repository }

  # @intent: { entity: "Repeated descriptions rollup", action: "find repetition within a declared layer", behavior: "layer=request surfaces a description repeated inside the request layer that the unasked default top ten cannot show, ranked first, with the asked layer echoed and the limit unchanged", layer: "request" }
  it "ranks within the layer and surfaces a group the unasked top ten drops" do
    names = repeated["rows"].map { it["name"] }
    expect(names.size).to eq(SpecObservation::REPEATED_DESCRIPTIONS_LIMIT)
    expect(names).not_to include("A request loop")

    block = repeated(query: { layer: "request" })

    expect(block["rows"].map { it["name"] }).to eq(["A request loop"])
    expect(block["layer"]).to eq("request")
    expect(block["limit"]).to eq(SpecObservation::REPEATED_DESCRIPTIONS_LIMIT)
  end

  # @intent: { entity: "Repeated descriptions rollup", action: "find repetition within a declared layer", behavior: "a description with exactly one request and one unit example is absent under request and under unit and present unasked", layer: "request" }
  it "does not report a description repeated only across layers" do
    expect(get_repository["latest_run"]["repeated_descriptions"]["rows"].map { it["name"] }).not_to include("straddle")
    all = SpecObservation.repeated_descriptions_in(run, limit: 100).map(&:first)
    expect(all).to include("straddle")

    expect(repeated(query: { layer: "request" })["rows"].map { it["name"] }).not_to include("straddle")
    expect(repeated(query: { layer: "unit" })["rows"].map { it["name"] }).not_to include("straddle")
  end

  # @intent: { entity: "Repeated descriptions rollup", action: "count within a declared layer", behavior: "under a layer each row's recorded, timed and layer counts and the group, recorded and unnamed totals are the layer's, with named rows reconciling", layer: "request" }
  it "counts the layer's own population" do
    block = repeated(query: { layer: "request" })
    row = block["rows"].first

    expect(row).to include("recorded_count" => 4, "timed_count" => 4, "total_seconds" => 12.0,
                           "layer_counts" => { "unit" => 0, "integration" => 0, "request" => 4, "system" => 0, "undeclared" => 0 })
    expect(block["group_count"]).to eq(1)
    expect(block["repeated_recorded_count"]).to eq(4)
    expect(block["repeated_timed_count"]).to eq(4)
    expect(block["recorded_count"]).to eq(run.spec_observations.where(intent_layer: "request").count)
    expect(block["recorded_count"]).to eq(latest_run["layer_counts"]["request"])
    expect(block["unnamed_row_count"]).to eq(1)
    expect(block["recorded_count"] - block["unnamed_row_count"]).to eq(5)
  end

  # @intent: { entity: "Repeated descriptions rollup", action: "select the undeclared layer", behavior: "layer=undeclared selects intent_layer IS NULL rows, so an undeclared pair under spec/requests is undeclared and the request layer does not see it", layer: "request" }
  it "decides the layer by the stored declaration, never the path" do
    expect(repeated(query: { layer: "undeclared" })["rows"].map { it["name"] }).to eq(["plain pair"])
    expect(repeated(query: { layer: "request" })["rows"].map { it["name"] }).not_to include("plain pair")
  end

  # @intent: { entity: "Repeated descriptions rollup", action: "ignore unknown layers", behavior: "an unknown, array, NUL or blank layer is no ask and serves a body deep-equal to the unasked one with no layer key on either block", layer: "request" }
  it "reads every malformed or unknown ask as no ask, body identical to unasked" do
    baseline = unasked.except("api_key")

    ["?layer=bogus", "?layer[]=request", "?layer[a]=request", "?layer=%00", "?layer=", "?layer=REQUEST"].each do |suffix|
      body = raw_get("/api/v1/repository#{suffix}")

      expect(response).to have_http_status(:ok), suffix
      expect(body).to eq(baseline), suffix
    end
    expect(baseline["latest_run"]["repeated_descriptions"]).not_to have_key("layer")
    expect(baseline["latest_run"]["repeated_descriptions"].keys).to contain_exactly(
      "rows", "group_count", "recorded_count", "unnamed_row_count", "repeated_recorded_count",
      "repeated_timed_count", "limit"
    )
  end

  # @intent: { entity: "Repeated descriptions rollup", action: "keep the recorded gate run-level", behavior: "a layer no example declared serves a present block with empty rows and group_count 0, while a run that recorded nothing stays null with or without the ask", layer: "system" }
  it "serves an empty block, not null, for a layer nobody declared; null stays a run-level fact" do
    block = repeated(query: { layer: "system" })

    expect(block).to include("rows" => [], "group_count" => 0, "recorded_count" => 0, "layer" => "system")

    bare = create_test_run(repository: repository, commit_sha: "desclayer002", branch: "main",
                           total_specs_count: 5, duration_seconds: 1.0, created_at: 1.hour.from_now)
    expect(bare.spec_observations).to be_empty
    expect(latest_run).to have_key("repeated_descriptions")
    expect(repeated).to be_nil
    expect(repeated(query: { layer: "request" })).to be_nil
  end

  # @intent: { entity: "Repeated description examples drill-in", action: "open a group within a declared layer", behavior: "opening a straddling description under a layer lists only that layer's examples and its recorded and timed counts equal the ranking row's, echoing the layer only when asked", layer: "request" }
  it "narrows the drill-in so the opened group equals the clicked row" do
    row = repeated(query: { layer: "request" })["rows"].first
    block = examples(query: { layer: "request", repeated_description: "A request loop" })

    expect(block["layer"]).to eq("request")
    expect(block["recorded_count"]).to eq(row["recorded_count"])
    expect(block["timed_count"]).to eq(row["timed_count"])
    expect(block["rows"].map { it["intent_layer"] }.uniq).to eq(["request"])

    straddle = examples(query: { layer: "request", repeated_description: "straddle" })
    expect(straddle["recorded_count"]).to eq(1)
    expect(straddle["rows"].map { it["intent_layer"] }).to eq(["request"])

    unlayered = examples(query: { repeated_description: "straddle" })
    expect(unlayered).not_to have_key("layer")
    expect(unlayered["recorded_count"]).to eq(2)
    expect(unlayered.keys).to contain_exactly("name", "rows", "recorded_count", "timed_count", "limit")
  end

  # @intent: { entity: "Repeated descriptions rollup", action: "mirror the show rows under a layer", behavior: "repeated_descriptions rows under a layer match the presenter repositories#show assigns row for row and in the same order", layer: "request" }
  it "serves the same rows the dashboard presenter ranks under the layer" do
    shown = RepeatedDescriptions.for(repository.latest_test_run, layer: "request")
    block = repeated(query: { layer: "request" })

    expect(block["rows"].map { it["name"] }).to eq(shown.rows.map(&:name))
    expect(block["group_count"]).to eq(shown.group_count)
    expect(block["recorded_count"]).to eq(shown.recorded_count)
  end

  describe "what the layer ask costs" do
    # @intent: { entity: "Repository latest-run endpoint", action: "read the by-description grain", behavior: "an asked layer issues the same one grouped ranking statement and one presence statement as the unasked request, carrying the layer predicate", layer: "request" }
    it "keeps the pair of statements, asked or not" do
      ranking = ->(sqls) { sqls.select { it.include?("GROUP BY \"spec_observations\".\"name\"") } }
      presence = ->(sqls) { sqls.select { it.include?("COUNT(*) FILTER (WHERE name IS NULL)") } }
      unasked_sqls = queries_against("spec_observations") { get_repository }
      asked_sqls = queries_against("spec_observations") { get_repository(query: { layer: "request" }) }

      expect(ranking.(unasked_sqls).size).to eq(1)
      expect(ranking.(asked_sqls).size).to eq(1)
      expect(presence.(unasked_sqls).size).to eq(1)
      expect(presence.(asked_sqls).size).to eq(1)
      expect(ranking.(asked_sqls).first).to match(/WHERE .*intent_layer/m)
      expect(presence.(asked_sqls).first).to match(/WHERE .*intent_layer/m)
    end
  end
end
