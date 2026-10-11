# frozen_string_literal: true

require "rails_helper"

# The `layer_runtime_growth` pair on `GET /api/v1/repository` and the delta line under the Overview's
# "Time by declared layer" row — how the summed example DURATION per declared layer moved against the
# previous run on the same branch. Both are built from one `LayerRuntimeGrowth`.
#
# Rows are written by `Ingest::RunRecorder` (never inserted by hand).
RSpec.describe "GET /api/v1/repository — layer_runtime_growth", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:layers) { %w[unit integration request system undeclared] }

  def get_repository(repo: repository, query: {})
    token = repo.api_keys.create!.raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  def blocks(**)
    body = get_repository(**)
    [body["layer_runtime_growth_window"], body["layer_runtime_growth"]]
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

  def comparable_runs(repo: repository, branch: "main")
    ingest(timed_mix("unit" => [1.0, 1.0], "request" => [2.0, 3.0], "undeclared" => [0.5]),
           commit_sha: "previous0001", at: 20.days.ago, repo: repo, branch: branch)
    ingest(timed_mix("unit" => [1.0, 1.0], "request" => [22.0, 24.2], "undeclared" => [0.25]),
           commit_sha: "latest000001", at: 10.days.ago, repo: repo, branch: branch)
  end

  describe "two comparable runs on a branch" do
    before { comparable_runs }

    # @intent: { entity: "layer_runtime_growth", action: "serve the time movement", behavior: "request layer 5.0s then 46.2s serves baseline, anchor and change 41.2, an unmoved layer as a measured zero change, all five layers in the closed enum order", layer: "request" }
    it "serves per-layer seconds, timed counts and change in the closed enum order" do
      window, block = blocks

      expect(window).to include("basis" => "previous_run_on_branch", "branch" => "main", "state" => "comparable",
                                "comparable" => true, "anchor_commit_sha" => "latest000001",
                                "baseline_commit_sha" => "previous0001")
      expect(block.keys).to eq(["layers"])
      expect(block["layers"].keys).to eq(layers)
      expect(block["layers"]["request"]).to include("baseline_seconds" => 5.0, "anchor_seconds" => 46.2,
                                                    "baseline_timed_count" => 2, "anchor_timed_count" => 2,
                                                    "baseline_count" => 2, "anchor_count" => 2)
      expect(block["layers"]["request"]["change"]).to be_within(0.001).of(41.2)
      expect(block["layers"]["unit"]["change"]).to eq(0.0)
      expect(block["layers"]["undeclared"]["change"]).to be_within(0.001).of(-0.25)
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold a layer nobody ran", behavior: "a layer with no examples on either side serves null seconds and a null change, never zero", layer: "request" }
    it "serves a null change for a layer untimed on both sides" do
      _window, block = blocks

      expect(block["layers"]["system"]).to include("baseline_seconds" => nil, "anchor_seconds" => nil,
                                                   "change" => nil, "baseline_timed_count" => 0)
    end

    # @intent: { entity: "layer_runtime_growth", action: "sit beside layer_run_growth", behavior: "the pair is top-level and absent from latest_run", layer: "request" }
    it "is top-level and not inside latest_run" do
      body = get_repository

      expect(body).to have_key("layer_runtime_growth")
      expect(body["latest_run"]).not_to have_key("layer_runtime_growth")
      expect(body["latest_run"]).not_to have_key("layer_runtime_growth_window")
    end

    # @intent: { entity: "layer_runtime_growth", action: "add no query", behavior: "serving the time movement reads the run-grain layer aggregate exactly as often as layer_run_growth alone did, twice", layer: "request" }
    it "issues no run-grain read beyond the two layer_run_growth already makes" do
      expect(run_layer_mix_reads { get_repository }.length).to eq(2)
    end

    # @intent: { entity: "layer_runtime_growth", action: "re-anchor on commit_sha", behavior: "naming the earlier run anchors on it exactly as layer_run_growth_window does", layer: "request" }
    it "re-anchors with ?commit_sha= like layer_run_growth_window" do
      ingest(timed_mix("unit" => [9.0]), commit_sha: "newest000001", at: 1.day.ago)

      body = get_repository(query: { commit_sha: "latest000001" })

      expect(body["layer_runtime_growth_window"]).to eq(body["layer_run_growth_window"])
      expect(body["layer_runtime_growth_window"]).to include("state" => "comparable")
    end
  end

  describe "movement the count pair cannot see" do
    # @intent: { entity: "layer_runtime_growth", action: "see a slowdown with equal counts", behavior: "two runs with the same request example count and a longer total request duration serve a positive request time change while layer_run_growth serves request change 0", layer: "request" }
    it "reads positive where the count pair reads zero" do
      ingest(timed_mix("request" => [1.0, 1.0]), commit_sha: "previous0001", at: 20.days.ago)
      ingest(timed_mix("request" => [1.0, 41.0]), commit_sha: "latest000001", at: 10.days.ago)

      body = get_repository

      expect(body["layer_run_growth"]["layers"]["request"]["change"]).to eq(0)
      expect(body["layer_runtime_growth"]["layers"]["request"]["change"]).to be_within(0.001).of(40.0)
    end
  end

  describe "a layer untimed on one side of a comparable pair" do
    # @intent: { entity: "layer_runtime_growth", action: "refuse to difference against null", behavior: "a layer whose examples were untimed in the previous run serves a null change and its operands, never a difference against zero", layer: "request" }
    it "serves a null change for that layer only" do
      ingest(timed_mix("unit" => [1.0], "request" => [nil]), commit_sha: "previous0001", at: 20.days.ago)
      ingest(timed_mix("unit" => [3.0], "request" => [50.0]), commit_sha: "latest000001", at: 10.days.ago)

      _window, block = blocks

      expect(block["layers"]["request"]).to include("baseline_seconds" => nil, "anchor_seconds" => 50.0,
                                                    "baseline_timed_count" => 0, "anchor_timed_count" => 1,
                                                    "baseline_count" => 1, "change" => nil)
      expect(block["layers"]["unit"]["change"]).to eq(2.0)
    end
  end

  describe "every non-comparable state" do
    def expect_withheld(state)
      window, block = blocks

      expect(window).to include("state" => state, "comparable" => false)
      expect(block).to be_nil
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold on a first run", behavior: "the first run on a branch serves no_previous_run and a null block", layer: "request" }
    it "serves no_previous_run on the first run on a branch" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "only00000001", at: 1.day.ago)

      expect_withheld("no_previous_run")
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold with no runs", behavior: "a repository CI has never reported on serves no_latest_run, a null block and a null anchor", layer: "request" }
    it "serves no_latest_run when CI has never reported" do
      window, block = blocks

      expect(window).to include("state" => "no_latest_run", "comparable" => false, "anchor_commit_sha" => nil)
      expect(block).to be_nil
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold before reading", behavior: "a previous run that reported no tests serves previous_unmeasured without reading its layer time", layer: "request" }
    it "serves previous_unmeasured and reads the previous run's mix never" do
      ingest([], commit_sha: "previous0001", at: 20.days.ago, total: 0)
      ingest(timed_mix("unit" => [1.0]), commit_sha: "latest000001", at: 10.days.ago)

      expect_withheld("previous_unmeasured")
      expect(run_layer_mix_reads { get_repository }.length).to eq(1)
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold before reading", behavior: "a latest run that reported no tests serves latest_unmeasured without reading the previous layer time", layer: "request" }
    it "serves latest_unmeasured and reads the previous run's mix never" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "previous0001", at: 20.days.ago)
      ingest([], commit_sha: "latest000001", at: 10.days.ago, total: 0)

      expect_withheld("latest_unmeasured")
      expect(run_layer_mix_reads { get_repository }.length).to eq(1)
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold on differently assembled runs", behavior: "runs assembled from different shard counts serve assembled_differently without reading the previous layer time", layer: "request" }
    it "serves assembled_differently without a previous-run read" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "previous0001", at: 20.days.ago)
      ingest(timed_mix("unit" => [1.0]), commit_sha: "latest000001", at: 10.days.ago)
      allow_any_instance_of(TestRun).to receive(:assembled_like?).and_return(false) # rubocop:disable RSpec/AnyInstance

      expect_withheld("assembled_differently")
      expect(run_layer_mix_reads { get_repository }.length).to eq(1)
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold against a totals-only run", behavior: "a previous run with a suite size and no per-example rows serves previous_unrecorded and a null block", layer: "request" }
    it "serves previous_unrecorded" do
      ingest([], commit_sha: "previous0001", at: 20.days.ago, total: 10)
      ingest(timed_mix("unit" => [1.0]), commit_sha: "latest000001", at: 10.days.ago)

      expect_withheld("previous_unrecorded")
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold from a totals-only run", behavior: "a latest run with no per-example rows serves latest_unrecorded and a null block", layer: "request" }
    it "serves latest_unrecorded" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "previous0001", at: 20.days.ago)
      ingest([], commit_sha: "latest000001", at: 10.days.ago, total: 10)

      expect_withheld("latest_unrecorded")
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold when neither run recorded", behavior: "two totals-only runs serve neither_recorded and a null block", layer: "request" }
    it "serves neither_recorded" do
      ingest([], commit_sha: "previous0001", at: 20.days.ago, total: 10)
      ingest([], commit_sha: "latest000001", at: 10.days.ago, total: 10)

      expect_withheld("neither_recorded")
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold when neither run was timed", behavior: "two runs that recorded rows and timed none serve neither_timed and a null block rather than zero seconds", layer: "request" }
    it "serves neither_timed" do
      ingest(timed_mix("unit" => [nil]), commit_sha: "previous0001", at: 20.days.ago)
      ingest(timed_mix("unit" => [nil]), commit_sha: "latest000001", at: 10.days.ago)

      expect_withheld("neither_timed")
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold against an untimed previous run", behavior: "a previous run that recorded rows and timed none serves previous_untimed and a null block, never the whole latest run as new time", layer: "request" }
    it "serves previous_untimed" do
      ingest(timed_mix("unit" => [nil]), commit_sha: "previous0001", at: 20.days.ago)
      ingest(timed_mix("unit" => [4.0]), commit_sha: "latest000001", at: 10.days.ago)

      expect_withheld("previous_untimed")
    end

    # @intent: { entity: "layer_runtime_growth", action: "withhold from an untimed latest run", behavior: "a latest run that recorded rows and timed none serves latest_untimed and a null block, never the previous time as vanished", layer: "request" }
    it "serves latest_untimed" do
      ingest(timed_mix("unit" => [4.0]), commit_sha: "previous0001", at: 20.days.ago)
      ingest(timed_mix("unit" => [nil]), commit_sha: "latest000001", at: 10.days.ago)

      expect_withheld("latest_untimed")
    end
  end

  describe "the Overview panel line" do
    def runtime_line = Capybara.string(response.body).find("#changes #layer-runtime-growth")

    # @intent: { entity: "TestRun", action: "show the time movement", behavior: "the Overview prints Since the previous sha7 on main with request +41.20s from the same object the API serves", layer: "request" }
    it "prints the movement under Time by declared layer when comparable" do
      comparable_runs

      get repository_path(repository)

      expect(runtime_line).to have_text("Since previou on main:", normalize_ws: true)
      expect(runtime_line).to have_text("unit ±0 · request +41.20s · undeclared −0.25s", normalize_ws: true)
    end

    # @intent: { entity: "TestRun", action: "omit the time movement without a comparison", behavior: "a first run on a branch renders Time by declared layer and no movement line", layer: "request" }
    it "omits the line when there is no comparison" do
      ingest(timed_mix("unit" => [1.0]), commit_sha: "only00000001", at: 1.day.ago)

      get repository_path(repository)

      html = Capybara.string(response.body)
      expect(html).to have_css("#layer-durations")
      expect(html).to have_no_css("#layer-runtime-growth")
    end

    # @intent: { entity: "TestRun", action: "omit the time movement when untimed", behavior: "a previous run that timed nothing renders no movement line", layer: "request" }
    it "omits the line when the previous run is untimed" do
      ingest(timed_mix("unit" => [nil]), commit_sha: "previous0001", at: 20.days.ago)
      ingest(timed_mix("unit" => [4.0]), commit_sha: "latest000001", at: 10.days.ago)

      get repository_path(repository)

      expect(Capybara.string(response.body)).to have_no_css("#layer-runtime-growth")
    end

    # @intent: { entity: "TestRun", action: "agree with the API", behavior: "the request figure on the panel is the API's request change spelled through humanized_duration", layer: "request" }
    it "agrees with the API figures" do
      comparable_runs
      change = get_repository["layer_runtime_growth"]["layers"]["request"]["change"]

      get repository_path(repository)

      expect(runtime_line).to have_text("request +#{SpecObservation.humanized_duration(change)}", normalize_ws: true)
    end
  end
end
