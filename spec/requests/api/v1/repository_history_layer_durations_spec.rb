# frozen_string_literal: true

require "rails_helper"

# `history[].layer_durations` on `GET /api/v1/repository` — the declared-layer MACHINE TIME per run
# across the history window (SPGD-1829), the time twin of `history[].layer_counts` (SPGD-1819).
#
# Per-layer time was only ever served as `latest_run.layer_durations` (one run) and as MOVEMENT
# between two points (`layer_runtime_growth`, `layer_runtime_window_growth`), so a step could not be
# told from noise. Each history row now carries exactly `TestRun#layer_durations`, primed for the
# window by the SAME single grouped read that primes `layer_counts` — no statement was added.
#
# Operands only, DECLARED layers only; `null` for a run with no per-example rows; `total_seconds`
# null (never 0) for a layer with no timed example.
RSpec.describe "GET /api/v1/repository — history[].layer_durations", type: :request do
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

  # One example per entry of `durations` (layer => [seconds, …]); a nil is an untimed example.
  def timed_mix(durations, prefix)
    durations.flat_map do |layer, seconds_list|
      seconds_list.each_with_index.map do |seconds, index|
        file = "spec/#{prefix}_#{layer}_#{index + 1}_spec.rb"
        if layer == "undeclared"
          unannotated_spec(file_path: file, line_number: index + 1, name: "#{prefix} #{layer} #{index}", duration: seconds)
        else
          annotated_spec(file_path: file, line_number: index + 1, layer: layer, name: "#{prefix} #{layer} #{index}",
                         duration: seconds)
        end
      end
    end
  end

  # Three same-composition runs whose request time steps up then falls back — the rise-and-fall that
  # reads ±0 at the two endpoints. `system` is never timed; `integration` is never present.
  def three_timed_runs
    ingest(timed_mix({ "unit" => [1.0, 2.0], "request" => [3.0], "system" => [nil], "undeclared" => [0.5] }, "a"),
           commit_sha: "timerun00001")
    ingest(timed_mix({ "unit" => [1.0, 2.0], "request" => [30.0, 10.0], "system" => [nil], "undeclared" => [0.5] }, "b"),
           commit_sha: "timerun00002")
    ingest(timed_mix({ "unit" => [1.0, 2.0], "request" => [3.0], "system" => [nil], "undeclared" => [0.5] }, "c"),
           commit_sha: "timerun00003")
  end

  describe "a branch window of runs with differing layer times" do
    before { three_timed_runs }

    # @intent: { entity: "history layer_durations", action: "match the run detail", behavior: "each history row's layer_durations equals that run's latest_run.layer_durations key for key", layer: "request" }
    it "serves, on each row, exactly what that run's detail serves as latest_run.layer_durations" do
      body = get_repository(query: { branch: "main" })

      expect(body["history"].map { |row| row["commit_sha"] }).to eq(%w[timerun00003 timerun00002 timerun00001])
      body["history"].each do |row|
        detail = get_repository(query: { commit_sha: row["commit_sha"] })["latest_run"]

        expect(detail["commit_sha"]).to eq(row["commit_sha"])
        expect(row["layer_durations"]).to eq(detail["layer_durations"])
        expect(row["layer_durations"].keys).to eq(layer_keys)
        row["layer_durations"].each_value { |layer| expect(layer.keys).to eq(%w[total_seconds timed_count]) }
      end
    end

    # The rows genuinely DIFFER, and an untimed layer is null with a zero timed count (never 0 s).
    # @intent: { entity: "history layer_durations", action: "serve a per-run series", behavior: "each row carries its own run's per-layer seconds, a layer with no timed example serves total_seconds null with timed_count 0", layer: "request" }
    it "serves each run its own seconds, and null (not 0) for a layer with no timed example" do
      rows = get_repository(query: { branch: "main" })["history"].reverse

      expect(rows.map { |row| row.dig("layer_durations", "request") }).to eq(
        [{ "total_seconds" => 3.0, "timed_count" => 1 },
         { "total_seconds" => 40.0, "timed_count" => 2 },
         { "total_seconds" => 3.0, "timed_count" => 1 }]
      )
      rows.each do |row|
        durations = row["layer_durations"]
        expect(durations["unit"]).to eq("total_seconds" => 3.0, "timed_count" => 2)
        expect(durations["undeclared"]).to eq("total_seconds" => 0.5, "timed_count" => 1)
        expect(durations["integration"]).to eq("total_seconds" => nil, "timed_count" => 0)
        expect(durations["system"]).to eq("total_seconds" => nil, "timed_count" => 0)
      end
    end

    # @intent: { entity: "history layer_durations", action: "append last", behavior: "layer_durations is the last key of every history row and the earlier keys keep their order", layer: "request" }
    it "appends layer_durations as the LAST key, after layer_counts" do
      keys = get_repository(query: { branch: "main" })["history"].map(&:keys)

      expect(keys.uniq.length).to eq(1)
      expect(keys.first).to eq(
        %w[commit_sha branch total_specs annotated_specs annotated_ratio duration_seconds shard_count
           timed_shard_count suite_size_measured ingested_at layer_counts layer_durations]
      )
    end

    # AC: the window pays the SAME single grouped statement as before — not one more, not one per row.
    # @intent: { entity: "history layer_durations", action: "prime once", behavior: "layer_counts and layer_durations are primed by exactly one grouped spec_observations read, at one, ten and thirty rows", layer: "request" }
    it "primes counts and durations with exactly one grouped spec_observations read, however many rows" do
      grouped = lambda do
        executed_sql { get_repository(query: { branch: "main" }) }
          .grep(/FROM "spec_observations"/).grep(/GROUP BY "spec_observations"\."test_run_id"/)
      end

      get_repository(query: { branch: "main" })
      expect(grouped.call.length).to eq(1)
      expect(grouped.call.first).to include("run_layer_request_seconds")

      27.times do |i|
        ingest(timed_mix({ "unit" => [1.0 + i] }, "m#{i}"), commit_sha: "more#{i.to_s.rjust(8, '0')}")
      end
      expect(get_repository(query: { branch: "main" })["history"].length).to eq(30)
      expect(grouped.call.length).to eq(1)
    end

    # Mutation check: without the priming, `layer_durations` falls back to the memoized RUN-grain aggregate
    # (`run_counts_in`, no GROUP BY) once per history row. The latest run and the previous run each pay
    # one of those anyway (latest_run, layer_run_growth); the primed window must add none beyond them.
    # @intent: { entity: "history layer_durations", action: "refuse a per-row aggregate", behavior: "removing the window priming makes the history pay one ungrouped run-grain aggregate per row, which the primed window does not", layer: "request" }
    it "pays no per-row run aggregate (and would pay one per row if the priming were removed)" do
      get_repository(query: { branch: "main" })
      ungrouped = lambda do
        executed_sql { get_repository(query: { branch: "main" }) }
          .grep(/AS run_layer_unit_seconds/).grep_v(/GROUP BY "spec_observations"\."test_run_id"/)
      end
      primed = ungrouped.call.length

      allow_any_instance_of(TestRun).to receive(:preload_layer_durations).and_return(nil)
      unprimed = ungrouped.call.length

      expect(unprimed).to be > primed
      expect(unprimed - primed).to be >= 1
    end
  end

  describe "a run with no per-example rows" do
    # @intent: { entity: "history layer_durations", action: "serve null for an unrecorded run", behavior: "a run that stored no per-example rows serializes layer_durations null and its neighbours keep theirs", layer: "request" }
    it "serializes null on its own row and leaves the other rows alone" do
      ingest(timed_mix({ "unit" => [2.0] }, "r"), commit_sha: "recorded0001")
      create_test_run(repository: repository, commit_sha: "norows000001", branch: "main")
      ingest(timed_mix({ "request" => [4.0, 5.0] }, "s"), commit_sha: "recorded0002")

      rows = get_repository(query: { branch: "main" })["history"].index_by { |row| row["commit_sha"] }

      expect(rows.fetch("norows000001")).to have_key("layer_durations")
      expect(rows.fetch("norows000001")["layer_durations"]).to be_nil
      expect(rows.fetch("recorded0001")["layer_durations"]["unit"]).to eq("total_seconds" => 2.0, "timed_count" => 1)
      expect(rows.fetch("recorded0002")["layer_durations"]["request"]).to eq("total_seconds" => 9.0, "timed_count" => 2)
    end
  end

  describe "the neighbouring objects" do
    # @intent: { entity: "history layer_durations", action: "leave the growth objects untouched", behavior: "layer_run_growth, layer_runtime_growth and layer_runtime_window_growth keep their documented keys", layer: "request" }
    it "keeps layer_runtime_window_growth a two-endpoint comparison with its own keys" do
      three_timed_runs

      body = get_repository(query: { branch: "main" })

      expect(body.dig("layer_runtime_window_growth_window", "basis")).to eq("two_endpoints")
      expect(body["layer_runtime_window_growth"].keys).to eq(%w[layers])
      expect(body["layer_runtime_window_growth"]["layers"]["request"]).to eq(
        "baseline_seconds" => 3.0, "anchor_seconds" => 3.0, "baseline_timed_count" => 1, "anchor_timed_count" => 1,
        "baseline_count" => 1, "anchor_count" => 1, "change" => 0.0
      )
      expect(body["layer_runtime_growth"].keys).to eq(%w[layers])
      expect(body["layer_run_growth"].keys).to contain_exactly("layers", "baseline_recorded_count", "anchor_recorded_count")
    end
  end
end
