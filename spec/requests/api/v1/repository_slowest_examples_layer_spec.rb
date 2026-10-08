# frozen_string_literal: true

require "rails_helper"

# `?layer=` on `GET /api/v1/repository` (SPGD-1685) — narrows ONLY `latest_run.slowest_examples` to one
# DECLARED layer, so "the request layer holds most of the machine time" (`layer_durations`) has a route
# to WHICH tests. The layer is what each example's `@intent` declared, never inferred from the path.
#
# The fixture holds all four enum layers plus undeclared, with durations interleaved across layers so the
# run-wide top ten is NOT the request layer's top ten — the case the parameter exists for. A twelve-row
# unit tail pushes every request row below the run-wide cut.
RSpec.describe "GET /api/v1/repository — ?layer= on slowest_examples", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }
  let(:layer_keys) { %w[unit integration request system undeclared] }

  def get_repository(query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def latest_run(query: {}) = get_repository(query: query)["latest_run"]

  def slowest(query: {}) = latest_run(query: query)["slowest_examples"]

  # `api_key.last_used_at` is stamped on every authenticated request at one-second resolution, so a
  # whole-body comparison across two requests flakes on a second boundary. It describes the credential
  # and not the ask, so it is the one key dropped before bodies are compared.
  def raw_get(path)
    get path, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }
    response.parsed_body.except("api_key")
  end

  def observe(run, line:, duration:, layer:, path: "spec/mixed/#{layer || 'none'}_spec.rb", outcome: "passed")
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "#{layer} example #{line}",
      outcome: outcome, intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "layerask0001", branch: "main",
                               total_specs_count: 30, duration_seconds: 90.0)
    # Twelve unit rows, all slower than any request row: the run-wide top ten is unit only.
    12.times { |i| observe(test_run, line: i + 1, duration: 50.0 - i, layer: "unit") }
    # Request: five timed, one untimed — the layer's own coverage differs from the run's.
    [9.0, 4.5, 4.5, 2.0, 1.0].each_with_index { |d, i| observe(test_run, line: 100 + i, duration: d, layer: "request") }
    observe(test_run, line: 110, duration: nil, layer: "request", outcome: nil)
    observe(test_run, line: 120, duration: 7.0, layer: "integration")
    observe(test_run, line: 130, duration: 6.0, layer: "system", outcome: "failed")
    # Undeclared lives under spec/requests/ — the path must not make it `request`.
    observe(test_run, line: 140, duration: 8.0, layer: nil, path: "spec/requests/login_spec.rb")
    observe(test_run, line: 141, duration: 0.5, layer: nil, path: "spec/requests/login_spec.rb")
    test_run
  end

  # THE NO-ASK BODY every malformed ask must equal.
  let(:unasked) { get_repository }

  # @intent: { entity: "Slowest examples ranking", action: "narrow to a declared layer", behavior: "layer=request serves exactly the request-layer rows, duration descending then id ascending, each declaring request, with the asked layer echoed", layer: "request" }
  it "serves exactly the asked layer's rows in ranking order" do
    block = slowest(query: { layer: "request" })

    expected = run.spec_observations.where(intent_layer: "request").where.not(duration_seconds: nil)
                  .order(duration_seconds: :desc, id: :asc).pluck(:line_number)

    expect(block["rows"].map { it["line_number"] }).to eq(expected)
    expect(block["rows"].map { it["intent_layer"] }).to all(eq("request"))
    expect(block["layer"]).to eq("request")
    expect(block["limit"]).to eq(SpecObservation::SLOWEST_LIMIT)
    # The run-wide ranking does NOT contain them — the point of the parameter.
    expect(slowest["rows"].map { it["intent_layer"] }).to all(eq("unit"))
  end

  # The shared-predicate claim, pinned: the ranking's counts are the SAME numbers `layer_counts` and
  # `layer_durations` serve, because all three are built from `declared_layer_predicates`.
  # @intent: { entity: "Slowest examples ranking", action: "share the layer predicate", behavior: "the asked layer's recorded_count and timed_count equal layer_counts and layer_durations timed_count for the same run", layer: "request" }
  it "counts the layer exactly as layer_counts and layer_durations do" do
    body = latest_run(query: { layer: "request" })
    block = body["slowest_examples"]

    expect(block["recorded_count"]).to eq(6)
    expect(block["recorded_count"]).to eq(body["layer_counts"]["request"])
    expect(block["timed_count"]).to eq(5)
    expect(block["timed_count"]).to eq(body["layer_durations"]["request"]["timed_count"])
    expect(block["reported_outcome_count"]).to eq(5)
  end

  # @intent: { entity: "Slowest examples ranking", action: "narrow to undeclared", behavior: "layer=undeclared serves only rows whose intent_layer is null, never inferring request from the spec/requests path", layer: "request" }
  it "serves only rows that declared nothing for ?layer=undeclared" do
    block = slowest(query: { layer: "undeclared" })

    expect(block["rows"].map { it["intent_layer"] }).to all(be_nil)
    expect(block["rows"].map { it["line_number"] }).to eq([140, 141])
    expect(block["layer"]).to eq("undeclared")
    expect(block["recorded_count"]).to eq(latest_run["layer_counts"]["undeclared"])
  end

  # @intent: { entity: "Slowest examples ranking", action: "ignore unknown layers", behavior: "an unknown, array, NUL or blank layer is no ask and serves a body deep-equal to the unasked one", layer: "request" }
  it "reads every malformed or unknown ask as no ask — never a 400 or 404, body deep-equal to unasked" do
    baseline = unasked.except("api_key")

    ["?layer=bogus", "?layer[]=request", "?layer[a]=request", "?layer=%00", "?layer=", "?layer=REQUEST",
     "?layer=request%00"].each do |suffix|
      body = raw_get("/api/v1/repository#{suffix}")

      expect(response).to have_http_status(:ok), suffix
      expect(body).to eq(baseline), suffix
    end
    expect(baseline["latest_run"]["slowest_examples"]).not_to have_key("layer")
  end

  # @intent: { entity: "Slowest examples ranking", action: "keep the recorded gate run-level", behavior: "a layer no example declared serves rows empty and recorded_count 0 rather than null, while a run that recorded nothing stays null with or without the ask", layer: "request" }
  it "serves an empty block, not null, for an asked layer with no rows; null stays a run-level fact" do
    other = create_test_run(repository: repository, commit_sha: "layerask0002", branch: "main",
                            total_specs_count: 1, duration_seconds: 1.0, created_at: 1.hour.from_now)
    observe(other, line: 1, duration: 1.0, layer: "unit")

    block = slowest(query: { layer: "system" })
    expect(block).to include("rows" => [], "recorded_count" => 0, "timed_count" => 0,
                             "reported_outcome_count" => 0, "layer" => "system")

    bare = create_test_run(repository: repository, commit_sha: "layerask0003", branch: "main",
                           total_specs_count: 5, duration_seconds: 1.0, created_at: 2.hours.from_now)
    expect(bare.spec_observations).to be_empty
    expect(latest_run).to have_key("slowest_examples")
    expect(slowest).to be_nil
    expect(slowest(query: { layer: "request" })).to be_nil
  end

  # @intent: { entity: "Slowest examples ranking", action: "re-anchor with the run", behavior: "layer composes with commit_sha and re-anchors with the run, and narrows no other drill-in block", layer: "request" }
  it "re-anchors with ?commit_sha= and narrows no other block" do
    newer = create_test_run(repository: repository, commit_sha: "layerask0004", branch: "main",
                            total_specs_count: 1, duration_seconds: 1.0, created_at: 1.hour.from_now)
    observe(newer, line: 1, duration: 3.0, layer: "request", path: "spec/new_spec.rb")

    anchored = latest_run(query: { layer: "request", commit_sha: "layerask0001" })
    expect(anchored["commit_sha"]).to eq("layerask0001")
    expect(anchored["slowest_examples"]["recorded_count"]).to eq(6)

    current = latest_run(query: { layer: "request" })
    expect(current["commit_sha"]).to eq("layerask0004")
    expect(current["slowest_examples"]["rows"].map { it["spec_file_path"] }).to eq(["spec/new_spec.rb"])

    with_file = latest_run(query: { layer: "request", commit_sha: "layerask0001",
                                    spec_file: "spec/mixed/unit_spec.rb" })
    expect(with_file["spec_file_examples"]["recorded_count"]).to eq(12)
    expect(with_file["spec_file_examples"]["rows"].map { it["intent_layer"] }.uniq).to eq(["unit"])
    expect(with_file["slowest_examples"]["layer"]).to eq("request")
  end

  # The unasked path is byte-identical: no `layer` key, same keys the contract pins.
  # @intent: { entity: "Slowest examples ranking", action: "leave the unasked body unchanged", behavior: "without a layer ask the slowest_examples block carries no layer key and exactly the previously pinned keys", layer: "request" }
  it "adds no key to the unasked block" do
    expect(slowest.keys).to contain_exactly("rows", "recorded_count", "timed_count", "reported_outcome_count", "limit")
    expect(slowest(query: { layer: "request" }).keys)
      .to contain_exactly("layer", "rows", "recorded_count", "timed_count", "reported_outcome_count", "limit")
  end

  describe "what the layer ask costs" do
    # @intent: { entity: "Repository latest-run endpoint", action: "read the per-example grain twice", behavior: "an asked layer reads spec_observations exactly as often as the unasked request, two per-example reads and one run aggregate", layer: "request" }
    it "issues the same two per-example reads and the same total, asked or not" do
      unasked_reads = observation_reads { get_repository }
      asked_reads = observation_reads { get_repository(query: { layer: "request" }) }

      expect(example_grain_reads { get_repository(query: { layer: "request" }) }.length).to eq(2)
      expect(asked_reads.length).to eq(unasked_reads.length)
      expect(asked_reads.length).to eq(classified_observation_reads { get_repository(query: { layer: "request" }) })
      # The layer is applied in SQL, in BOTH reads — never in Ruby after the fact.
      per_example = example_grain_reads { get_repository(query: { layer: "request" }) }
      expect(per_example).to all(include("intent_layer = 'request'"))
    end
  end
end
