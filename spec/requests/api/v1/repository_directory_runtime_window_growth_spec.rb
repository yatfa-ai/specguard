# frozen_string_literal: true

require "rails_helper"

# The `directory_runtime_window_growth` pair on `GET /api/v1/repository?branch=` and the "Areas that got
# slower or faster over the window" panel of repositories#show (SPGD-1788) — how the summed example
# DURATION per area moved across the branch window's two ENDPOINTS. Both are built from one
# `SpecDirectoryWindowRuntimeGrowth`, off the baseline `WindowBaseline` shares with `directory_growth`,
# `layer_growth` and `layer_runtime_window_growth`, so they are asserted off one fixture.
#
# Rows are written by `Ingest::RunRecorder`, so every state is one the recorder produces from what a
# real client sends.
RSpec.describe "GET /api/v1/repository — directory_runtime_window_growth", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def get_repository(query: {})
    token = repository.api_keys.create!.raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  def blocks(query: { branch: "main" })
    body = get_repository(query: query)
    [body["directory_runtime_window_growth_window"], body["directory_runtime_window_growth"]]
  end

  def ingest(specs, commit_sha:, at:, branch: "main", total: nil)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, total_specs_count: total || specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at)
    run
  end

  # `areas` is `{ "spec/models" => { layer: "request", seconds: [20.0, 20.0] }, ... }`; one example per
  # entry of `seconds` (nil is an untimed example), each in its own file under the area.
  def timed_areas(areas)
    areas.flat_map do |directory, config|
      config.fetch(:seconds).each_with_index.map do |seconds, index|
        file = "#{directory}/#{config.fetch(:layer)}_#{index + 1}_spec.rb"
        name = "#{directory} #{config.fetch(:layer)} #{index + 1}"
        if config.fetch(:layer) == "undeclared"
          unannotated_spec(file_path: file, line_number: index + 1, name: name, duration: seconds)
        else
          annotated_spec(file_path: file, line_number: index + 1, layer: config.fetch(:layer), name: name,
                         duration: seconds)
        end
      end
    end
  end

  # Three same-sharded runs: spec/models has the SAME two request examples at every run and its time goes
  # 40s -> 41s (decoy) -> 110s; spec/jobs and spec/services are flat. Example counts are equal at every
  # run, so `directory_growth` must read spec/models as unmoved.
  def creeping_window
    ingest(timed_areas("spec/models" => { layer: "request", seconds: [20.0, 20.0] },
                       "spec/jobs" => { layer: "unit", seconds: [5.0] },
                       "spec/services" => { layer: "unit", seconds: [2.0] }),
           commit_sha: "baseline0001", at: 30.days.ago)
    ingest(timed_areas("spec/models" => { layer: "request", seconds: [20.0, 21.0] },
                       "spec/jobs" => { layer: "unit", seconds: [5.0] },
                       "spec/services" => { layer: "unit", seconds: [2.0] }),
           commit_sha: "middle000001", at: 20.days.ago)
    ingest(timed_areas("spec/models" => { layer: "request", seconds: [55.0, 55.0] },
                       "spec/jobs" => { layer: "unit", seconds: [5.0] },
                       "spec/services" => { layer: "unit", seconds: [2.0] }),
           commit_sha: "anchor000001", at: 10.days.ago)
  end

  def observation_read_count(query: { branch: "main" }) = observation_reads { get_repository(query: query) }.length

  describe "a branch-scoped window whose area crept with no example added" do
    before { creeping_window }

    # @intent: { entity: "directory_runtime_window_growth", action: "rank the area that crept", behavior: "spec/models ranks first with baseline 40.0, anchor 110.0 and change 70.0 across the window's two ends, the block keys and row keys in the documented order", layer: "request" }
    it "ranks the area first with the endpoint change and the documented key order" do
      window, block = blocks

      expect(window).to include("basis" => "two_endpoints", "branch_scope" => "single_branch", "branch" => "main",
                                "grouped" => true, "state" => "comparable", "comparable" => true,
                                "anchor_commit_sha" => "anchor000001", "baseline_commit_sha" => "baseline0001",
                                "runs_back" => 2, "limit" => SpecObservation::RETIMED_DIRECTORIES_LIMIT,
                                "order" => "abs_change_desc_nulls_last,path_asc", "tie_break_served" => true)
      expect(window).not_to have_key("layer")
      expect(block.keys).to eq(%w[rows directory_count truncated baseline_recorded_count anchor_recorded_count
                                  baseline_timed_count anchor_timed_count limit])
      expect(block).not_to have_key("layer")
      expect(block["rows"].first).to eq("path" => "spec/models", "baseline_seconds" => 40.0,
                                        "anchor_seconds" => 110.0, "change" => 70.0, "comparable" => true,
                                        "moved" => true, "new_area" => false, "removed_area" => false,
                                        "timing_gap" => false)
      expect(block["rows"].drop(1).map { it["change"] }).to eq([0.0, 0.0])
      expect([block["directory_count"], block["truncated"]]).to eq([3, false])
      expect([block["baseline_recorded_count"], block["anchor_recorded_count"],
              block["baseline_timed_count"], block["anchor_timed_count"]]).to eq([4, 4, 4, 4])
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "show time movement the count window and the last push cannot", behavior: "the same area reads change 0 on directory_growth and only the middle-to-anchor delta 69.0 on directory_runtime_growth while the window block reads 70.0", layer: "request" }
    it "reads change 0 on directory_growth and only the single-push delta on directory_runtime_growth" do
      body = get_repository(query: { branch: "main" })

      count_row = body["directory_growth"]["rows"].find { it["path"] == "spec/models" }
      push_row = body["directory_runtime_growth"]["rows"].find { it["path"] == "spec/models" }
      window_row = body["directory_runtime_window_growth"]["rows"].find { it["path"] == "spec/models" }

      expect(count_row["change"]).to eq(0)
      expect(push_row["change"]).to eq(69.0)
      expect(window_row["change"]).to eq(70.0)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "read only the two ends", behavior: "rewriting the middle run's durations leaves the endpoint answer byte-identical", layer: "request" }
    it "is unchanged when the middle run changes (two-endpoint contract)" do
      before_block = blocks.last
      TestRun.find_by!(commit_sha: "middle000001").spec_observations.update_all(duration_seconds: 900.0)

      expect(blocks.last).to eq(before_block)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "share the baseline walk", behavior: "directory_growth, layer_growth, layer_runtime_window_growth and the area time window name the same baseline commit, anchor commit and runs_back", layer: "request" }
    it "names the same baseline commit, anchor commit and runs_back as the other window blocks" do
      body = get_repository(query: { branch: "main" })
      keys = %w[baseline_commit_sha anchor_commit_sha runs_back]
      mine = body["directory_runtime_window_growth_window"].slice(*keys)

      expect(mine).to eq(body["layer_growth_window"].slice(*keys))
      expect(mine).to eq(body["layer_runtime_window_growth_window"].slice(*keys))
      expect(mine).to eq(body["directory_growth"].slice(*keys))
      expect(mine["baseline_commit_sha"]).to eq("baseline0001")
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "be absent without a branch", behavior: "without ?branch= the block is null, grouped is false, state is null and no spec_observations read is added", layer: "request" }
    it "serves null and grouped: false without ?branch=, adding no observation read" do
      window, block = blocks(query: {})

      expect(block).to be_nil
      expect(window).to eq("order" => "abs_change_desc_nulls_last,path_asc", "tie_break_served" => true,
                           "basis" => "two_endpoints", "branch_scope" => "all_branches", "branch" => nil,
                           "grouped" => false, "state" => nil, "comparable" => false,
                           "anchor_commit_sha" => nil, "baseline_commit_sha" => nil, "runs_back" => nil,
                           "limit" => SpecObservation::RETIMED_DIRECTORIES_LIMIT)
      allow(SpecDirectoryWindowRuntimeGrowth).to receive(:for).and_call_original
      get_repository(query: {})
      expect(SpecDirectoryWindowRuntimeGrowth).not_to have_received(:for)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "bound its reads", behavior: "a comparable window adds exactly one spec_observations read over the same request with the presenter stubbed out", layer: "request" }
    it "adds exactly one observation read when comparable" do
      with_block = observation_read_count
      allow(SpecDirectoryWindowRuntimeGrowth).to receive(:for).and_return(nil)
      without_block = observation_read_count

      expect(with_block - without_block).to eq(1)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "sit beside layer_runtime_window_growth", behavior: "the pair is top-level, directly after layer_runtime_window_growth, and absent from latest_run", layer: "request" }
    it "is top-level and ordered beside layer_runtime_window_growth" do
      body = get_repository(query: { branch: "main" })
      keys = body.keys

      expect(keys.index("directory_runtime_window_growth_window")).to eq(keys.index("layer_runtime_window_growth") + 1)
      expect(body["latest_run"]).not_to have_key("directory_runtime_window_growth")
    end
  end

  describe "?layer= on a window where one layer's time crept" do
    before do
      ingest(timed_areas("spec/models" => { layer: "request", seconds: [10.0] },
                         "spec/jobs" => { layer: "request", seconds: [3.0] },
                         "spec/services" => { layer: "unit", seconds: [2.0] }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_areas("spec/models" => { layer: "request", seconds: [50.0] },
                         "spec/jobs" => { layer: "request", seconds: [9.0] },
                         "spec/services" => { layer: "unit", seconds: [2.0] }),
             commit_sha: "anchor000001", at: 10.days.ago)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "narrow to a declared layer", behavior: "?layer=request lists only request areas, echoes the layer on both blocks, and the area changes sum to the layer_runtime_window_growth request change when every area is timed at both ends", layer: "request" }
    it "narrows, echoes the layer and sums to the layer window change" do
      body = get_repository(query: { branch: "main", layer: "request" })
      window = body["directory_runtime_window_growth_window"]
      block = body["directory_runtime_window_growth"]

      expect(window["layer"]).to eq("request")
      expect(block["layer"]).to eq("request")
      expect(block["rows"].map { it["path"] }).to eq(%w[spec/models spec/jobs])
      expect(block["rows"].all? { it["comparable"] }).to be(true)
      expect(block["rows"].sum { it["change"] })
        .to be_within(0.001).of(body["layer_runtime_window_growth"]["layers"]["request"]["change"])
      expect([block["baseline_recorded_count"], block["anchor_recorded_count"]]).to eq([2, 2])
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "treat a bogus layer as no ask", behavior: "?layer=bogus serves the unnarrowed block with no layer key, byte-identical to no layer", layer: "request" }
    it "reads a malformed layer as no ask" do
      expect(blocks(query: { branch: "main", layer: "bogus" })).to eq(blocks)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "echo no layer without a branch", behavior: "?layer=request without ?branch= leaves the window block without a layer key and the block null", layer: "request" }
    it "claims no narrowing when nothing was grouped" do
      window, block = blocks(query: { layer: "request" })

      expect(block).to be_nil
      expect(window).not_to have_key("layer")
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "answer a layer empty at both ends", behavior: "a layer neither end declared is comparable with no rows and directory_count 0, not a refusal", layer: "system" }
    it "is comparable with no rows for a layer neither end has" do
      window, block = blocks(query: { branch: "main", layer: "system" })

      expect(window).to include("state" => "comparable", "comparable" => true, "layer" => "system")
      expect(block).to include("rows" => [], "directory_count" => 0, "truncated" => false, "layer" => "system")
    end
  end

  describe "a layer present at the anchor only" do
    # @intent: { entity: "directory_runtime_window_growth", action: "name new areas for a layer the baseline lacked", behavior: "?layer=system with system examples only at the anchor is comparable with every row new_area true and change null", layer: "system" }
    it "serves every area as new_area" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }, "spec/system" => { layer: "system", seconds: [4.0] }),
             commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks(query: { branch: "main", layer: "system" })

      expect(block["rows"]).to eq([{ "path" => "spec/system", "baseline_seconds" => nil, "anchor_seconds" => 4.0,
                                     "change" => nil, "comparable" => false, "moved" => false,
                                     "new_area" => true, "removed_area" => false, "timing_gap" => false }])
    end
  end

  describe "an area untimed at one end of an otherwise comparable window" do
    # @intent: { entity: "directory_runtime_window_growth", action: "never difference against zero", behavior: "an area whose baseline examples were all untimed serves change null, timing_gap true and is listed after every timed area", layer: "request" }
    it "serves change null, sorted last" do
      ingest(timed_areas("spec/models" => { layer: "request", seconds: [nil] }, "spec/jobs" => { layer: "unit", seconds: [1.0] }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_areas("spec/models" => { layer: "request", seconds: [9.0] }, "spec/jobs" => { layer: "unit", seconds: [4.0] }),
             commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks

      expect(block["rows"].map { it["path"] }).to eq(%w[spec/jobs spec/models])
      expect(block["rows"].last).to include("baseline_seconds" => nil, "anchor_seconds" => 9.0, "change" => nil,
                                            "timing_gap" => true, "comparable" => false)
    end
  end

  describe "every non-comparable state" do
    def expect_withheld(state, query: { branch: "main" }, reads: 0)
      window, block = blocks(query: query)

      expect(window).to include("state" => state, "comparable" => false, "grouped" => true)
      expect(block).to be_nil
      expect(area_window_reads(query: query)).to eq(reads)
    end

    # The area-grain TIME window read is `directory_runtime_growth_between` handed the window's ends; its
    # SQL is identical to the previous-run pair's, so this counts it as a difference against the same
    # request with the presenter stubbed out.
    def area_window_reads(query:)
      with_block = observation_read_count(query: query)
      allow(SpecDirectoryWindowRuntimeGrowth).to receive(:for).and_return(nil)
      with_block - observation_read_count(query: query)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold with no baseline rows", behavior: "a baseline run that wrote no per-example rows serves baseline_unrecorded and a null block after its one read", layer: "request" }
    it "serves baseline_unrecorded when the oldest comparable run wrote no per-example rows" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("baseline_unrecorded", reads: 1)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold from a totals-only anchor", behavior: "an anchor that wrote no per-example rows serves anchor_unrecorded and a null block", layer: "request" }
    it "serves anchor_unrecorded when the newest run wrote no per-example rows" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("anchor_unrecorded", reads: 1)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold when neither end recorded", behavior: "two totals-only ends serve neither_recorded and a null block", layer: "request" }
    it "serves neither_recorded when neither end wrote per-example rows" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("neither_recorded", reads: 1)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold an untimed baseline", behavior: "a baseline whose examples were all untimed serves baseline_untimed and a null block, not a speedup from zero", layer: "request" }
    it "serves baseline_untimed when no example at the oldest end was timed" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [nil] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [2.0] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("baseline_untimed", reads: 1)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold an untimed anchor", behavior: "an anchor whose examples were all untimed serves anchor_untimed and a null block", layer: "request" }
    it "serves anchor_untimed when no example at the newest end was timed" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [2.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [nil] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("anchor_untimed", reads: 1)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold when neither end was timed", behavior: "two ends with only untimed examples serve neither_timed and a null block", layer: "request" }
    it "serves neither_timed when no example at either end was timed" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [nil] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [nil] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("neither_timed", reads: 1)
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold before reading", behavior: "a window of one run serves no_earlier_run, null shas and runs_back, and issues no observation read of its own", layer: "request" }
    it "serves no_earlier_run for a window of one run, reading nothing" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }), commit_sha: "only00000001", at: 1.day.ago)

      window, = blocks
      expect(window.values_at("baseline_commit_sha", "runs_back")).to eq([nil, nil])
      expect(window["anchor_commit_sha"]).to eq("only00000001")
      expect_withheld("no_earlier_run")
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold before reading", behavior: "an anchor that reported no tests serves anchor_unmeasured and issues no observation read of its own", layer: "request" }
    it "serves anchor_unmeasured when the newest run reported no tests" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 0)

      expect_withheld("anchor_unmeasured")
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold before reading", behavior: "earlier runs that all reported no tests serve no_measured_baseline without an observation read of its own", layer: "request" }
    it "serves no_measured_baseline when every earlier run reported no tests" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 0)
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("no_measured_baseline")
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "withhold before reading", behavior: "earlier runs assembled differently serve no_comparable_composition and a null block without an observation read of its own", layer: "request" }
    it "serves no_comparable_composition when every earlier run was assembled differently" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }), commit_sha: "anchor000001", at: 10.days.ago)
      allow_any_instance_of(TestRun).to receive(:assembled_like?).and_return(false) # rubocop:disable RSpec/AnyInstance

      expect_withheld("no_comparable_composition")
    end

    # @intent: { entity: "directory_runtime_window_growth", action: "carry the layer into a refusal", behavior: "a layered request refused by the walk still echoes the layer on the window block while the block is null", layer: "request" }
    it "echoes the layer on a refused window" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [1.0] }), commit_sha: "only00000001", at: 1.day.ago)

      window, block = blocks(query: { branch: "main", layer: "request" })

      expect(block).to be_nil
      expect(window).to include("state" => "no_earlier_run", "layer" => "request")
    end
  end

  describe "the panel" do
    def page = Capybara.string(response.body)

    def panel = page.find("#spec-directory-window-runtime-growth")

    def panel_text = panel.text.gsub(/\s+/, " ").strip

    # @intent: { entity: "GET /repositories/:id", action: "render the area time window panel", behavior: "a window whose area crept lists spec/models first with a +1m 10s change, worded as the window's two ends compared and never the run wall clock", layer: "request" }
    it "lists the area that crept, worded as the window's two ends" do
      creeping_window

      get repository_path(repository, branch: "main")

      expect(page).to have_css("#changes #spec-directory-window-runtime-growth")
      expect(panel).to have_text("Areas that got slower or faster over the window")
      expect(panel.all("tbody tr").first.all("td").first.text.strip).to eq("spec/models")
      expect(panel_text).to include("+#{SpecObservation.humanized_duration(70.0)}")
      expect(panel_text).to include("(not a trend)").and include("never the run wall clock")
      expect(panel_text).to include("Measured against baselin").and include("2 runs back in this window")
      expect(page.all("#spec-directory-window-runtime-growth-clear-layer")).to be_empty
    end

    # @intent: { entity: "GET /repositories/:id", action: "narrow the area time window panel", behavior: "?layer=request states the layer once with a clear link, lists the layer's areas and words the denominators as request-layer rows", layer: "request" }
    it "narrows under ?layer= and states the layer once" do
      ingest(timed_areas("spec/models" => { layer: "request", seconds: [10.0] }, "spec/services" => { layer: "unit", seconds: [2.0] }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_areas("spec/models" => { layer: "request", seconds: [50.0] }, "spec/services" => { layer: "unit", seconds: [9.0] }),
             commit_sha: "anchor000001", at: 10.days.ago)

      get repository_path(repository, branch: "main", layer: "request")

      expect(panel.all("tbody tr").map { it.all("td").first.text.strip }).to eq(["spec/models"])
      expect(panel_text).to include("Only the request-layer examples").and include("at both ends of this window")
      expect(panel_text).to include("request-layer example rows")
      expect(page.all("#spec-directory-window-runtime-growth-clear-layer").size).to eq(1)
      expect(page.find("#spec-directory-window-runtime-growth-clear-layer")[:href]).not_to include("layer=")
    end

    # @intent: { entity: "GET /repositories/:id", action: "word a layer empty at both ends", behavior: "a layer neither end declared renders the layer-empty state rather than a table or a refusal", layer: "system" }
    it "renders the layer-empty state" do
      creeping_window

      get repository_path(repository, branch: "main", layer: "system")

      expect(panel_text).to include("No system-layer examples at either end of this window")
      expect(panel.all("tbody tr")).to be_empty
    end

    # @intent: { entity: "GET /repositories/:id", action: "word comparable but unmoved", behavior: "two ends with identical area times render the no-area-changed-pace state naming only the two ends were compared", layer: "request" }
    it "renders the unmoved state" do
      2.times do |index|
        ingest(timed_areas("spec/models" => { layer: "unit", seconds: [3.0] }), commit_sha: "same0000000#{index}", at: (30 - (index * 20)).days.ago)
      end

      get repository_path(repository, branch: "main")

      expect(panel_text).to include("No area changed pace across this window")
      expect(panel_text).to include("Only those two ends were compared")
    end

    # @intent: { entity: "GET /repositories/:id", action: "word a refused window", behavior: "an untimed baseline renders the baseline-untimed refusal naming the commit and the reporting gap, with no table", layer: "request" }
    it "renders a refusal state with the run it landed on" do
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [nil] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_areas("spec/models" => { layer: "unit", seconds: [2.0] }), commit_sha: "anchor000001", at: 10.days.ago)

      get repository_path(repository, branch: "main")

      expect(panel_text).to include("reported no timings").and include("The run at the far end of this window")
      expect(panel_text).to include("not a speedup").or include("newly appearing")
      expect(panel.all("tbody tr")).to be_empty
    end

    # @intent: { entity: "GET /repositories/:id", action: "list the new title in the layer-scope hint", behavior: "the filter bar's narrowed-sections hint names the new panel title when a layer is asked", layer: "request" }
    it "names the panel in the narrowed-sections hint" do
      creeping_window

      get repository_path(repository, branch: "main", layer: "request")

      expect(page.find("#rc-layer-scope").text.squish).to include("Areas that got slower or faster over the window")
    end
  end
end
