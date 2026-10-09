# frozen_string_literal: true

require "rails_helper"

# The `layer_runtime_window_growth` pair on `GET /api/v1/repository?branch=` and the line under the
# Overview's "Areas that grew or shrank over the window" panel — how the summed example DURATION per
# declared layer moved across the branch window's two ENDPOINTS. Both are built from one
# `LayerWindowRuntimeGrowth`, off the baseline `WindowBaseline` shares with `directory_growth` and
# `layer_growth`, so they are asserted off one fixture.
#
# Rows are written by `Ingest::RunRecorder` (never inserted by hand), so every state is one the
# recorder produces from what a real client sends.
RSpec.describe "GET /api/v1/repository — layer_runtime_window_growth", type: :request do
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
    [body["layer_runtime_window_growth_window"], body["layer_runtime_window_growth"]]
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

  # One example per entry of `durations` (a layer => [seconds, ...] hash), each in its own file; a
  # nil duration is an untimed example. The path is never consulted.
  def timed_mix(durations)
    durations.flat_map do |layer, seconds_list|
      seconds_list.each_with_index.map do |seconds, index|
        file = "spec/models/#{layer}_#{index + 1}_spec.rb"
        name = "#{layer} example #{index + 1}"
        if layer == "undeclared"
          unannotated_spec(file_path: file, line_number: index + 1, name: name, duration: seconds)
        else
          annotated_spec(file_path: file, line_number: index + 1, layer: layer, name: name, duration: seconds)
        end
      end
    end
  end

  # Three same-sharded runs whose layer times all differ: the MIDDLE is a decoy, so comparing adjacent
  # runs rather than the two ends would serve different numbers.
  def comparable_window(repo: repository, branch: "main")
    ingest(timed_mix("unit" => [1.0, 1.0], "request" => [2.0, 3.0], "undeclared" => [0.5]),
           commit_sha: "baseline0001", at: 30.days.ago, repo: repo, branch: branch)
    ingest(timed_mix("unit" => [9.0, 9.0], "request" => [50.0, 60.0], "undeclared" => [7.0]),
           commit_sha: "middle000001", at: 20.days.ago, repo: repo, branch: branch)
    ingest(timed_mix("unit" => [1.0, 1.0], "request" => [22.0, 24.2], "undeclared" => [0.25]),
           commit_sha: "anchor000001", at: 10.days.ago, repo: repo, branch: branch)
  end

  def layer_reads(**) = run_layer_mix_reads { get_repository(**) }.length

  describe "a branch-scoped window of three comparable runs" do
    before { comparable_window }

    # @intent: { entity: "layer_runtime_window_growth", action: "serve the window time movement", behavior: "oldest comparable run request 5.0s against newest 46.2s serves baseline, anchor, timed counts, counts and change 41.2 in the closed enum order, an unmoved layer as a measured zero", layer: "request" }
    it "serves per-layer seconds, timed counts and change between the two ends" do
      window, block = blocks

      expect(window).to include("basis" => "two_endpoints", "branch_scope" => "single_branch", "branch" => "main",
                                "grouped" => true, "state" => "comparable", "comparable" => true,
                                "anchor_commit_sha" => "anchor000001", "baseline_commit_sha" => "baseline0001",
                                "runs_back" => 2)
      expect(block.keys).to eq(["layers"])
      expect(block["layers"].keys).to eq(layers)
      expect(block["layers"]["request"]).to include("baseline_seconds" => 5.0, "anchor_seconds" => 46.2,
                                                    "baseline_timed_count" => 2, "anchor_timed_count" => 2,
                                                    "baseline_count" => 2, "anchor_count" => 2)
      expect(block["layers"]["request"]["change"]).to be_within(0.001).of(41.2)
      expect(block["layers"]["unit"]["change"]).to eq(0.0)
      expect(block["layers"]["undeclared"]["change"]).to be_within(0.001).of(-0.25)
      expect(block["layers"]["system"]).to include("baseline_seconds" => nil, "anchor_seconds" => nil,
                                                   "baseline_count" => 0, "anchor_count" => 0, "change" => nil)
      expect(block["layers"]["request"].keys).to eq(
        %w[baseline_seconds anchor_seconds baseline_timed_count anchor_timed_count baseline_count anchor_count change]
      )
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "share the baseline walk", behavior: "directory_growth, layer_growth and layer_runtime_window_growth name the same baseline commit, anchor commit and runs_back for one fixture", layer: "request" }
    it "names the same baseline commit, anchor commit and runs_back as directory_growth and layer_growth" do
      body = get_repository(query: { branch: "main" })
      time = body["layer_runtime_window_growth_window"]

      keys = %w[baseline_commit_sha anchor_commit_sha runs_back]
      expect(time.slice(*keys)).to eq(body["layer_growth_window"].slice(*keys))
      expect(time.slice(*keys)).to eq(body["directory_growth"].slice(*keys))
      expect(time["baseline_commit_sha"]).to eq("baseline0001")
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "share the baseline walk when it steps over runs", behavior: "an unmeasured oldest run is skipped and the block compares the middle run to the anchor", layer: "request" }
    it "agrees with layer_growth when the walk steps over an unmeasured run" do
      TestRun.find_by!(commit_sha: "baseline0001").update_columns(total_specs_count: 0)

      body = get_repository(query: { branch: "main" })

      expect(body["layer_runtime_window_growth_window"]).to include("baseline_commit_sha" => "middle000001",
                                                                    "runs_back" => 1, "state" => "comparable")
      expect(body["layer_runtime_window_growth_window"]["runs_back"]).to eq(body["layer_growth_window"]["runs_back"])
      expect(body["layer_runtime_window_growth"]["layers"]["unit"]["change"]).to eq(-16.0)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "be absent without a branch", behavior: "without ?branch= the block is null, grouped is false, state is null and shas and runs_back are null", layer: "request" }
    it "serves null and grouped: false without ?branch=" do
      window, block = blocks(query: {})

      expect(block).to be_nil
      expect(window).to eq("basis" => "two_endpoints", "branch_scope" => "all_branches", "branch" => nil,
                           "grouped" => false, "state" => nil, "comparable" => false,
                           "anchor_commit_sha" => nil, "baseline_commit_sha" => nil, "runs_back" => nil)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "bound its reads", behavior: "the pair adds no run-layer aggregate beyond the two endpoint reads layer_growth already issues", layer: "request" }
    it "adds no observation read beyond the two endpoint reads layer_growth makes" do
      unfiltered = layer_reads
      named = layer_reads(query: { branch: "main" })

      expect(named - unfiltered).to eq(2)
      with_pair = observation_reads { get_repository(query: { branch: "main" }) }.length
      allow(LayerWindowRuntimeGrowth).to receive(:for).and_return(nil)
      without_pair = observation_reads { get_repository(query: { branch: "main" }) }.length

      expect(with_pair).to eq(without_pair)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "sit beside layer_growth", behavior: "the pair is top-level and absent from latest_run", layer: "request" }
    it "is top-level and not inside latest_run" do
      body = get_repository(query: { branch: "main" })

      expect(body).to have_key("layer_runtime_window_growth")
      expect(body["latest_run"]).not_to have_key("layer_runtime_window_growth")
    end
  end

  describe "a layer that got slower with no example added" do
    before do
      ingest(timed_mix("unit" => [1.0], "request" => [5.0, 5.0]), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_mix("unit" => [1.0], "request" => [30.0, 30.0]), commit_sha: "middle000001", at: 20.days.ago)
      ingest(timed_mix("unit" => [1.0], "request" => [35.0, 35.0]), commit_sha: "anchor000001", at: 10.days.ago)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "see time movement the count window cannot", behavior: "identical per-layer example counts at every run with request seconds 10 then 70 read layer_growth every change 0 and layer_runtime_window_growth request change 60.0", layer: "request" }
    it "reads change 0 on layer_growth and a positive change on the time block" do
      body = get_repository(query: { branch: "main" })

      expect(body["layer_growth"]["layers"].values.map { |layer| layer["change"] }).to all(eq(0))
      expect(body["layer_runtime_window_growth"]["layers"]["request"]["change"]).to eq(60.0)
      expect(body["layer_runtime_window_growth"]["layers"]["unit"]["change"]).to eq(0.0)
    end
  end

  describe "a layer untimed on one end of an otherwise comparable window" do
    # @intent: { entity: "layer_runtime_window_growth", action: "never difference against zero", behavior: "a request layer whose examples were all untimed at the baseline serves change null for request only while unit stays measured", layer: "request" }
    it "serves change null for that layer only" do
      ingest(timed_mix("unit" => [1.0], "request" => [nil, nil]), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_mix("unit" => [3.0], "request" => [4.0, 5.0]), commit_sha: "anchor000001", at: 10.days.ago)

      window, block = blocks

      expect(window).to include("state" => "comparable", "comparable" => true)
      expect(block["layers"]["request"]).to include("baseline_seconds" => nil, "anchor_seconds" => 9.0,
                                                    "baseline_timed_count" => 0, "anchor_timed_count" => 2,
                                                    "change" => nil)
      expect(block["layers"]["unit"]["change"]).to eq(2.0)
    end
  end

  describe "every non-comparable state" do
    def expect_withheld(state, reads: nil)
      window, block = blocks

      expect(window).to include("state" => state, "comparable" => false, "grouped" => true)
      expect(block).to be_nil
      expect(layer_reads(query: { branch: "main" })).to eq(reads) if reads
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold with no baseline rows", behavior: "a baseline run that wrote no per-example rows serves baseline_unrecorded and a null block", layer: "request" }
    it "serves baseline_unrecorded when the oldest comparable run wrote no per-example rows" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest(timed_mix("unit" => [1.0]), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("baseline_unrecorded", reads: 4)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold from a totals-only anchor", behavior: "an anchor that wrote no per-example rows serves anchor_unrecorded and a null block", layer: "request" }
    it "serves anchor_unrecorded when the newest run wrote no per-example rows" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "baseline0001", at: 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("anchor_unrecorded", reads: 4)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold when neither end recorded", behavior: "two totals-only ends serve neither_recorded and a null block", layer: "request" }
    it "serves neither_recorded when neither end wrote per-example rows" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("neither_recorded", reads: 4)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold an untimed baseline", behavior: "a baseline whose examples were all untimed serves baseline_untimed and a null block, not a speedup from zero", layer: "request" }
    it "serves baseline_untimed when no example at the oldest end was timed" do
      ingest(timed_mix("unit" => [nil], "request" => [nil]), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_mix("unit" => [1.0], "request" => [2.0]), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("baseline_untimed")
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold an untimed anchor", behavior: "an anchor whose examples were all untimed serves anchor_untimed and a null block", layer: "request" }
    it "serves anchor_untimed when no example at the newest end was timed" do
      ingest(timed_mix("unit" => [1.0], "request" => [2.0]), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_mix("unit" => [nil], "request" => [nil]), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("anchor_untimed")
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold when neither end was timed", behavior: "two ends with only untimed examples serve neither_timed and a null block", layer: "request" }
    it "serves neither_timed when no example at either end was timed" do
      ingest(timed_mix("unit" => [nil]), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_mix("unit" => [nil]), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("neither_timed")
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold before reading", behavior: "a window of one run serves no_earlier_run and reads no layer mix for the window", layer: "request" }
    it "serves no_earlier_run for a window of one run, reading nothing for the window" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "only00000001", at: 1.day.ago)

      expect_withheld("no_earlier_run", reads: layer_reads)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold before reading", behavior: "an anchor that reported no tests serves anchor_unmeasured and reads no layer mix for the window", layer: "request" }
    it "serves anchor_unmeasured when the newest run reported no tests" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "baseline0001", at: 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 0)

      expect_withheld("anchor_unmeasured", reads: layer_reads)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold before reading", behavior: "earlier runs that all reported no tests serve no_measured_baseline without reading a layer mix for the window", layer: "request" }
    it "serves no_measured_baseline when every earlier run reported no tests" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 0)
      ingest(timed_mix("unit" => [1.0]), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("no_measured_baseline", reads: layer_reads)
    end

    # @intent: { entity: "layer_runtime_window_growth", action: "withhold before reading", behavior: "earlier runs assembled differently serve no_comparable_composition and a null block", layer: "request" }
    it "serves no_comparable_composition when every earlier run was assembled differently" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_mix("unit" => [1.0]), commit_sha: "anchor000001", at: 10.days.ago)
      allow_any_instance_of(TestRun).to receive(:assembled_like?).and_return(false) # rubocop:disable RSpec/AnyInstance

      expect_withheld("no_comparable_composition")
    end
  end

  describe "the Overview panel line" do
    def window_line = Capybara.string(response.body).find("#spec-directory-window-growth #layer-window-runtime-growth")

    # @intent: { entity: "TestRun", action: "show the window time movement", behavior: "the window panel prints the LayerWindowRuntimeGrowth label worded as the window's two ends, equal to the object's label", layer: "request" }
    it "prints the movement for a comparable window, worded by LayerWindowRuntimeGrowth#label" do
      comparable_window

      get repository_path(repository)

      expect(window_line).to have_text("two ends", normalize_ws: true)
      expect(window_line).to have_text("request +41.20s", normalize_ws: true)
      runs = RunWindow.oldest_first(repository.suite_size_trajectory(repository.test_runs.order(created_at: :desc).first))
      expect(window_line.text.squish).to include(LayerWindowRuntimeGrowth.for(runs, branch: "main").label)
    end

    # @intent: { entity: "TestRun", action: "omit the window time movement without a comparison", behavior: "a single-run window renders no layer-window-runtime-growth line", layer: "request" }
    it "omits the line when the window is not comparable" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "only00000001", at: 1.day.ago)

      get repository_path(repository)

      expect(Capybara.string(response.body)).to have_no_css("#layer-window-runtime-growth")
    end
  end
end
