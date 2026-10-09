# frozen_string_literal: true

require "rails_helper"

# The `layer_growth` pair on `GET /api/v1/repository?branch=` and the line under the Overview's
# "Areas that grew or shrank over the window" panel — how the DECLARED-LAYER MIX moved across the
# branch window's two ENDPOINTS. Both are built from one `LayerWindowGrowth`, off the baseline
# `WindowBaseline` shares with `directory_growth`, so they are asserted off one fixture.
#
# Rows are written by `Ingest::RunRecorder` (never inserted by hand), so every state is one the
# recorder produces from what a real client sends.
RSpec.describe "GET /api/v1/repository — layer_growth", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:layers) { %w[unit integration request system undeclared] }

  def get_repository(repo: repository, query: {})
    token = repo.api_keys.create!.raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  def blocks(query: { branch: "main" }, **)
    body = get_repository(query: query, **)
    [body["layer_growth_window"], body["layer_growth"]]
  end

  def ingest(specs, commit_sha:, at:, repo: repository, branch: "main", total: nil)
    run = Ingest::RunRecorder.record(
      repo,
      { commit_sha: commit_sha, branch: branch, total_specs_count: total || specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at)
    run
  end

  # `{"unit" => 2, "request" => 1}` as that many examples, each in its own file under spec/models
  # whatever the layer — the path is never consulted.
  def mix(counts)
    counts.flat_map do |layer, count|
      Array.new(count) do |index|
        n = index + 1
        file = "spec/models/#{layer}_#{n}_spec.rb"
        if layer == "undeclared"
          unannotated_spec(file_path: file, line_number: n, name: "Undeclared example #{n}")
        else
          annotated_spec(file_path: file, line_number: n, layer: layer, name: "#{layer} example #{n}")
        end
      end
    end
  end

  # Three same-sharded runs whose mixes all differ: the MIDDLE is a decoy, so comparing adjacent runs
  # rather than the two ends would serve different numbers.
  def comparable_window(repo: repository, branch: "main")
    ingest(mix("unit" => 2, "request" => 1, "undeclared" => 2), commit_sha: "baseline0001", at: 30.days.ago,
                                                                repo: repo, branch: branch)
    ingest(mix("unit" => 5, "request" => 9), commit_sha: "middle000001", at: 20.days.ago, repo: repo,
                                             branch: branch)
    ingest(mix("unit" => 2, "request" => 41), commit_sha: "anchor000001", at: 10.days.ago, repo: repo,
                                              branch: branch)
  end

  def layer_reads(**) = run_layer_mix_reads { get_repository(**) }.length

  describe "a branch-scoped window of three comparable runs" do
    before { comparable_window }

    # @intent: { entity: "layer_growth", action: "serve the window mix movement", behavior: "oldest comparable run unit 2 request 1 undeclared 2 against newest unit 2 request 41 serves request baseline 1 anchor 41 change 40 and every layer in the closed enum order", layer: "request" }
    it "serves per-layer baseline, anchor and change between the two ends" do
      window, block = blocks

      expect(window).to include("basis" => "two_endpoints", "branch_scope" => "single_branch", "branch" => "main",
                                "grouped" => true, "state" => "comparable", "comparable" => true,
                                "anchor_commit_sha" => "anchor000001", "baseline_commit_sha" => "baseline0001",
                                "runs_back" => 2)
      expect(block["layers"].keys).to eq(layers)
      expect(block["layers"]["request"]).to eq("baseline_count" => 1, "anchor_count" => 41, "change" => 40)
      expect(block["layers"]["undeclared"]).to eq("baseline_count" => 2, "anchor_count" => 0, "change" => -2)
      expect(block["layers"]["unit"]).to eq("baseline_count" => 2, "anchor_count" => 2, "change" => 0)
      expect(block["layers"]["system"]).to eq("baseline_count" => 0, "anchor_count" => 0, "change" => 0)
    end

    # @intent: { entity: "layer_growth", action: "reconcile with the recorded totals", behavior: "the five changes sum to anchor_recorded_count minus baseline_recorded_count", layer: "request" }
    it "sums the per-layer changes to the difference of the recorded populations" do
      _window, block = blocks

      expect(block["baseline_recorded_count"]).to eq(5)
      expect(block["anchor_recorded_count"]).to eq(43)
      expect(block["layers"].values.sum { |layer| layer["change"] })
        .to eq(block["anchor_recorded_count"] - block["baseline_recorded_count"])
    end

    # @intent: { entity: "layer_growth", action: "share the baseline walk", behavior: "directory_growth and layer_growth name the same baseline commit, anchor commit and runs_back for one fixture", layer: "request" }
    it "names the same baseline commit and runs_back as directory_growth" do
      body = get_repository(query: { branch: "main" })

      expect(body["layer_growth_window"]["baseline_commit_sha"]).to eq("baseline0001")
      expect(body["layer_growth_window"]["runs_back"]).to eq(body["directory_growth"]["runs_back"])
      expect(body["layer_growth_window"]["anchor_commit_sha"]).to be_present
    end

    # @intent: { entity: "layer_growth", action: "share the baseline walk when it steps over runs", behavior: "an unmeasured oldest run is skipped by both blocks, which then agree on the middle run and a shortened runs_back", layer: "request" }
    it "agrees with directory_growth when the walk steps over an unmeasured run" do
      TestRun.find_by!(commit_sha: "baseline0001").update_columns(total_specs_count: 0)

      body = get_repository(query: { branch: "main" })

      expect(body["layer_growth_window"]).to include("baseline_commit_sha" => "middle000001", "runs_back" => 1,
                                                     "state" => "comparable")
      expect(body["layer_growth_window"]["runs_back"]).to eq(body["directory_growth"]["runs_back"])
      expect(body["layer_growth"]["layers"]["unit"]).to eq("baseline_count" => 5, "anchor_count" => 2, "change" => -3)
    end

    # @intent: { entity: "layer_growth", action: "be absent without a branch", behavior: "without ?branch= the block is null, grouped is false, state is null and no run-layer read is added", layer: "request" }
    it "serves null and grouped: false without ?branch=, adding no layer read" do
      window, block = blocks(query: {})

      expect(block).to be_nil
      expect(window).to include("basis" => "two_endpoints", "branch_scope" => "all_branches", "branch" => nil,
                                "grouped" => false, "state" => nil, "comparable" => false,
                                "anchor_commit_sha" => nil, "baseline_commit_sha" => nil, "runs_back" => nil)
    end

    # Query budget (criterion 5): the comparable case adds exactly the two endpoint reads to what the
    # run-over-run pair already issues, and nothing at all unfiltered.
    # @intent: { entity: "layer_growth", action: "bound its reads", behavior: "a comparable branch-scoped window adds exactly two run-layer aggregates over the unfiltered request", layer: "request" }
    it "adds exactly two run-layer reads, one per endpoint run" do
      unfiltered = layer_reads
      named = layer_reads(query: { branch: "main" })

      expect(named - unfiltered).to eq(2)
      expect(unfiltered).to eq(2)
      reads = observation_reads { get_repository(query: { branch: "main" }) }
      expect(reads.length).to eq(classified_observation_reads { get_repository(query: { branch: "main" }) })
    end

    # @intent: { entity: "layer_growth", action: "sit beside directory_growth", behavior: "the pair is top-level and absent from latest_run", layer: "request" }
    it "is top-level and not inside latest_run" do
      body = get_repository(query: { branch: "main" })

      expect(body).to have_key("layer_growth")
      expect(body["latest_run"]).not_to have_key("layer_growth")
    end
  end

  describe "every non-comparable state" do
    def expect_withheld(state, reads:)
      window, block = blocks

      expect(window).to include("state" => state, "comparable" => false, "grouped" => true)
      expect(block).to be_nil
      expect(layer_reads(query: { branch: "main" })).to eq(reads)
    end

    # The unfiltered run-over-run pair reads the layer mix of the latest and previous run (2) when
    # both are measured and assembled alike; the window adds its own on top of that.
    # @intent: { entity: "layer_growth", action: "withhold with no baseline mix", behavior: "a baseline run that wrote no per-example rows serves baseline_unrecorded and a null block, never zeros", layer: "request" }
    it "serves baseline_unrecorded when the oldest comparable run wrote no per-example rows" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest(mix("unit" => 2), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("baseline_unrecorded", reads: 4)
    end

    # @intent: { entity: "layer_growth", action: "withhold from a totals-only anchor", behavior: "an anchor that wrote no per-example rows serves anchor_unrecorded and a null block", layer: "request" }
    it "serves anchor_unrecorded when the newest run wrote no per-example rows" do
      ingest(mix("unit" => 2), commit_sha: "baseline0001", at: 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("anchor_unrecorded", reads: 4)
    end

    # @intent: { entity: "layer_growth", action: "withhold when neither end recorded", behavior: "two totals-only ends serve neither_recorded and a null block", layer: "request" }
    it "serves neither_recorded when neither end wrote per-example rows" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("neither_recorded", reads: 4)
    end

    # The remaining states are decided from rows in memory: the window issues no layer read at all,
    # so the branch-scoped count equals the unfiltered (run-over-run) one.
    # @intent: { entity: "layer_growth", action: "withhold before reading", behavior: "a window of one run serves no_earlier_run and reads no layer mix for the window", layer: "request" }
    it "serves no_earlier_run for a window of one run, reading nothing for the window" do
      ingest(mix("unit" => 2), commit_sha: "only00000001", at: 1.day.ago)

      expect_withheld("no_earlier_run", reads: layer_reads)
    end

    # @intent: { entity: "layer_growth", action: "withhold before reading", behavior: "an anchor that reported no tests serves anchor_unmeasured and reads no layer mix for the window", layer: "request" }
    it "serves anchor_unmeasured when the newest run reported no tests" do
      ingest(mix("unit" => 2), commit_sha: "baseline0001", at: 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 0)

      expect_withheld("anchor_unmeasured", reads: layer_reads)
    end

    # @intent: { entity: "layer_growth", action: "withhold before reading", behavior: "earlier runs that all reported no tests serve no_measured_baseline without reading a layer mix for the window", layer: "request" }
    it "serves no_measured_baseline when every earlier run reported no tests" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 0)
      ingest(mix("unit" => 2), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("no_measured_baseline", reads: layer_reads)
    end

    # @intent: { entity: "layer_growth", action: "withhold before reading", behavior: "earlier runs assembled differently serve no_comparable_composition without reading a layer mix for the window", layer: "request" }
    it "serves no_comparable_composition when every earlier run was assembled differently" do
      ingest(mix("unit" => 2), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(mix("unit" => 2), commit_sha: "anchor000001", at: 10.days.ago)
      allow_any_instance_of(TestRun).to receive(:assembled_like?).and_return(false) # rubocop:disable RSpec/AnyInstance

      window, block = blocks

      expect(window).to include("state" => "no_comparable_composition", "comparable" => false)
      expect(block).to be_nil
    end
  end

  describe "the Overview panel line" do
    def window_line = Capybara.string(response.body).find("#spec-directory-window-growth #layer-window-growth")

    # @intent: { entity: "TestRun", action: "show the window mix movement", behavior: "the window panel prints the LayerWindowGrowth label with request +40 and undeclared −2 over 3 runs, equal to the object's label", layer: "request" }
    it "prints the movement for a comparable window, worded by LayerWindowGrowth#label" do
      comparable_window

      get repository_path(repository)

      expect(window_line).to have_text("unit ±0 · request +40 · undeclared −2 over 3 runs", normalize_ws: true)
      runs = RunWindow.oldest_first(repository.suite_size_trajectory(repository.test_runs.order(created_at: :desc).first))
      expect(window_line.text.squish).to include(LayerWindowGrowth.for(runs, branch: "main").label)
    end

    # @intent: { entity: "TestRun", action: "omit the window mix movement without a comparison", behavior: "a single-run window renders no layer-window-growth line", layer: "request" }
    it "omits the line when the window is not comparable" do
      ingest(mix("unit" => 2), commit_sha: "only00000001", at: 1.day.ago)

      get repository_path(repository)

      expect(Capybara.string(response.body)).to have_no_css("#layer-window-growth")
    end
  end
end
