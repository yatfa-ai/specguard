# frozen_string_literal: true

require "rails_helper"

# `history[].layer_counts` on `GET /api/v1/repository` — the declared-layer mix PER RUN across the
# history window (SPGD-1819).
#
# The mix was already served for ONE run (`latest_run.layer_counts`) and as MOVEMENT between two
# points (`layer_run_growth`, `layer_growth`), and nothing served it as a series, so "when did the
# request layer shift over the last 30 runs?" was unanswerable. Each history row now carries exactly
# `TestRun#layer_counts`, primed for the window by one grouped read.
#
# Operands only, DECLARED only (never inferred from a path); `null` — never five zeros — for a run
# that stored no per-example rows.
RSpec.describe "GET /api/v1/repository — history[].layer_counts", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }
  let(:layer_keys) { %w[unit integration request system undeclared] }

  def get_repository(query: {})
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    response.parsed_body
  end

  def ingest(specs, commit_sha:, branch: "main")
    payload = Ingest::Payload.new(
      { "commit_sha" => commit_sha, "branch" => branch, "duration_seconds" => 60.0,
        "specs" => specs.map(&:deep_stringify_keys) }
    )
    raise "ingest fixture is not a valid payload: #{payload.errors.inspect}" unless payload.valid?

    Ingest::RunRecorder.record(repository, payload.test_run_attributes, specs: payload.specs)
  end

  def layered(layer, count, prefix)
    Array.new(count) do |index|
      annotated_spec(file_path: "spec/#{prefix}_#{layer}_spec.rb", line_number: index + 1, layer: layer)
    end
  end

  def undeclared(count, prefix)
    Array.new(count) do |index|
      unannotated_spec(file_path: "spec/#{prefix}_none_spec.rb", line_number: index + 1,
                       name: "#{prefix} behaves #{index}")
    end
  end

  # Three same-composition (unsharded) runs whose mixes DIFFER: the request layer steps up, then
  # falls back — the rise-and-fall that reads ±0 at the two endpoints.
  def three_mixed_runs
    ingest(layered("unit", 3, "a") + layered("request", 1, "a") + undeclared(1, "a"), commit_sha: "mixrun000001")
    ingest(layered("unit", 3, "b") + layered("request", 4, "b") + layered("system", 1, "b") + undeclared(2, "b"),
           commit_sha: "mixrun000002")
    ingest(layered("unit", 3, "c") + layered("request", 1, "c") + undeclared(1, "c"), commit_sha: "mixrun000003")
  end

  describe "a branch window of runs with differing mixes" do
    before { three_mixed_runs }

    # AC1: key for key against each run's own detail, and summing to its recorded population.
    # @intent: { entity: "history layer_counts", action: "match the run detail", behavior: "each history row's layer_counts equals that run's latest_run.layer_counts key for key and sums to intent_readings.recorded", layer: "request" }
    it "serves, on each row, exactly what that run's detail serves as latest_run.layer_counts" do
      body = get_repository(query: { branch: "main" })

      expect(body["history"].map { |row| row["commit_sha"] }).to eq(%w[mixrun000003 mixrun000002 mixrun000001])
      body["history"].each do |row|
        detail = get_repository(query: { commit_sha: row["commit_sha"] })["latest_run"]

        expect(detail["commit_sha"]).to eq(row["commit_sha"])
        expect(row["layer_counts"]).to eq(detail["layer_counts"])
        expect(row["layer_counts"].keys).to eq(layer_keys)
        expect(row["layer_counts"].values.sum).to eq(detail["intent_readings"]["recorded"])
      end
    end

    # The rows genuinely DIFFER — otherwise the parity above would hold for a serializer that
    # copied one run's mix onto every row.
    # @intent: { entity: "history layer_counts", action: "serve a per-run series", behavior: "each row carries its own run's mix, so a rise and fall back is visible across rows", layer: "request" }
    it "serves each run its own mix, so a rise-and-fall-back is visible across the rows" do
      rows = get_repository(query: { branch: "main" })["history"].reverse

      expect(rows.map { |row| row["layer_counts"] }).to eq(
        [{ "unit" => 3, "integration" => 0, "request" => 1, "system" => 0, "undeclared" => 1 },
         { "unit" => 3, "integration" => 0, "request" => 4, "system" => 1, "undeclared" => 2 },
         { "unit" => 3, "integration" => 0, "request" => 1, "system" => 0, "undeclared" => 1 }]
      )
    end

    # @intent: { entity: "history layer_counts", action: "append last", behavior: "layer_counts is the last key of every history row and the earlier keys keep their order", layer: "request" }
    it "appends layer_counts as the LAST key, leaving every earlier key where it was" do
      keys = get_repository(query: { branch: "main" })["history"].map(&:keys)

      expect(keys.uniq.length).to eq(1)
      expect(keys.first).to eq(
        %w[commit_sha branch total_specs annotated_specs annotated_ratio duration_seconds shard_count
           timed_shard_count suite_size_measured ingested_at layer_counts]
      )
    end

    # AC3: one grouped statement whatever the window.
    # @intent: { entity: "history layer_counts", action: "prime once", behavior: "the whole window's layer_counts is primed by exactly one grouped spec_observations read", layer: "request" }
    it "primes the window with exactly one grouped spec_observations read" do
      get_repository(query: { branch: "main" })

      grouped = executed_sql { get_repository(query: { branch: "main" }) }
                .grep(/FROM "spec_observations"/).grep(/GROUP BY "spec_observations"\."test_run_id"/)

      expect(grouped.length).to eq(1)
    end
  end

  # AC2 + the null/zero trap: a run with no per-example rows is NULL on its row, and the other rows
  # are unaffected.
  describe "a run with no per-example rows" do
    # @intent: { entity: "history layer_counts", action: "serve null for an unrecorded run", behavior: "a run that stored no per-example rows serializes layer_counts null, never five zeros, and its neighbours keep theirs", layer: "request" }
    it "serializes null on its own row and leaves the other rows alone" do
      ingest(layered("unit", 2, "r") + undeclared(1, "r"), commit_sha: "recorded0001")
      create_test_run(repository: repository, commit_sha: "norows000001", branch: "main")
      ingest(layered("request", 2, "s"), commit_sha: "recorded0002")

      rows = get_repository(query: { branch: "main" })["history"].index_by { |row| row["commit_sha"] }

      expect(rows.fetch("norows000001")).to have_key("layer_counts")
      expect(rows.fetch("norows000001")["layer_counts"]).to be_nil
      expect(rows.fetch("recorded0001")["layer_counts"])
        .to eq("unit" => 2, "integration" => 0, "request" => 0, "system" => 0, "undeclared" => 1)
      expect(rows.fetch("recorded0002")["layer_counts"])
        .to eq("unit" => 0, "integration" => 0, "request" => 2, "system" => 0, "undeclared" => 0)
    end
  end

  # AC6, restated for what this change must NOT have touched.
  describe "the two-endpoint objects" do
    # @intent: { entity: "history layer_counts", action: "leave layer_growth untouched", behavior: "layer_growth keeps its two-endpoint basis and its own operands", layer: "request" }
    it "keeps layer_growth a two-endpoint comparison with its own keys" do
      three_mixed_runs

      body = get_repository(query: { branch: "main" })

      expect(body.dig("layer_growth_window", "basis")).to eq("two_endpoints")
      expect(body["layer_growth"].keys).to contain_exactly("layers", "baseline_recorded_count", "anchor_recorded_count")
      expect(body["layer_growth"]["layers"]["request"]).to eq("baseline_count" => 1, "anchor_count" => 1, "change" => 0)
    end
  end
end
