# frozen_string_literal: true

require "rails_helper"

# The `directory_runtime_window_file_growth` pair on `GET /api/v1/repository?branch=&spec_directory=`
# and the "Files that got slower or faster across the window" drill-in of repositories#show
# (SPGD-1803) — which FILES of one area got slower or faster across the branch window's two ENDPOINTS.
# The last empty cell of the {area, file} × {count, time} × {last push, branch window} grid. Both are
# built from one `SpecDirectoryWindowFileRuntimeGrowth`, off the parent `SpecDirectoryWindowRuntimeGrowth`.
#
# Rows are written by `Ingest::RunRecorder`, so every state is one the recorder produces from what a
# real client sends.
RSpec.describe "GET /api/v1/repository — directory_runtime_window_file_growth", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:area) { "spec/models" }

  def get_repository(query: {})
    token = repository.api_keys.create!.raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  def blocks(query: { branch: "main", spec_directory: area })
    body = get_repository(query: query)
    [body["directory_runtime_window_file_growth_window"], body["directory_runtime_window_file_growth"]]
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

  # `{ "spec/models/a_spec.rb" => { layer: "request", seconds: [10.0] } }` — one example per entry of
  # `seconds` (nil is an untimed example), all in that file.
  def timed_files(files)
    files.flat_map do |file, config|
      config.fetch(:seconds).each_with_index.map do |seconds, index|
        layer = config.fetch(:layer, "unit")
        name = "#{file} #{index + 1}"
        if layer == "undeclared"
          unannotated_spec(file_path: file, line_number: index + 1, name: name, duration: seconds)
        else
          annotated_spec(file_path: file, line_number: index + 1, layer: layer, name: name, duration: seconds)
        end
      end
    end
  end

  # F = spec/models/f_spec.rb: 10s at the baseline, `middle` in the middle run, 60s at the anchor.
  def window_with_f(middle: 10.0)
    ingest(timed_files("spec/models/f_spec.rb" => { layer: "request", seconds: [10.0] },
                       "spec/models/flat_spec.rb" => { seconds: [2.0] }),
           commit_sha: "baseline0001", at: 30.days.ago)
    ingest(timed_files("spec/models/f_spec.rb" => { layer: "request", seconds: [middle] },
                       "spec/models/flat_spec.rb" => { seconds: [2.0] }),
           commit_sha: "middle000001", at: 20.days.ago)
    ingest(timed_files("spec/models/f_spec.rb" => { layer: "request", seconds: [60.0] },
                       "spec/models/flat_spec.rb" => { seconds: [2.0] }),
           commit_sha: "anchor000001", at: 10.days.ago)
  end

  def observation_read_count(query: { branch: "main", spec_directory: area })
    observation_reads { get_repository(query: query) }.length
  end

  describe "a file that crept across the window" do
    before { window_with_f }

    # @intent: { entity: "directory_runtime_window_file_growth", action: "rank the file that crept", behavior: "f_spec.rb ranks first with baseline 10.0, anchor 60.0 and change 50.0, the block keys and row keys in the documented order, beside a window block naming both ends", layer: "request" }
    it "ranks the file first with the endpoint change and the documented key order" do
      window, block = blocks

      expect(window).to include("path" => area, "basis" => "two_endpoints", "branch_scope" => "single_branch",
                                "branch" => "main", "grouped" => true, "state" => "comparable",
                                "comparable" => true, "anchor_commit_sha" => "anchor000001",
                                "baseline_commit_sha" => "baseline0001", "runs_back" => 2,
                                "limit" => SpecObservation::SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT,
                                "order" => "abs_change_desc_nulls_last,path_asc", "tie_break_served" => true)
      expect(window).not_to have_key("layer")
      expect(block.keys).to eq(%w[rows file_count truncated baseline_recorded_count anchor_recorded_count
                                  baseline_timed_count anchor_timed_count])
      expect(block).not_to have_key("layer")
      expect(block["rows"].first).to eq("path" => "spec/models/f_spec.rb", "baseline_seconds" => 10.0,
                                        "anchor_seconds" => 60.0, "change" => 50.0, "comparable" => true,
                                        "moved" => true, "new_file" => false, "removed_file" => false,
                                        "timing_gap" => false)
      expect(block["rows"].last["change"]).to eq(0.0)
      expect([block["file_count"], block["truncated"]]).to eq([2, false])
      expect([block["baseline_recorded_count"], block["anchor_recorded_count"],
              block["baseline_timed_count"], block["anchor_timed_count"]]).to eq([2, 2, 2, 2])
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "see what the last-push block cannot", behavior: "when f_spec.rb rose in the final push the last-push block shows +50 while the window block shows +50 across its ends; when it rose earlier and held, the last-push block reads 0 and the window block still reads +50", layer: "request" }
    it "shows a creep the last-push block cannot see" do
      TestRun.where(commit_sha: %w[middle000001]).first.spec_observations
             .where(spec_file_path: "spec/models/f_spec.rb").update_all(duration_seconds: 60.0)

      body = get_repository(query: { branch: "main", spec_directory: area })
      push = body["directory_runtime_file_growth"]["rows"].find { it["path"] == "spec/models/f_spec.rb" }
      window = body["directory_runtime_window_file_growth"]["rows"].find { it["path"] == "spec/models/f_spec.rb" }

      expect(push["change"]).to eq(0.0)
      expect(window["change"]).to eq(50.0)
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "agree with the last push when the last push did it", behavior: "with the file flat until the final run the last-push block and the window block both read +50", layer: "request" }
    it "agrees with the last-push block when the final push moved the file" do
      body = get_repository(query: { branch: "main", spec_directory: area })
      push = body["directory_runtime_file_growth"]["rows"].find { it["path"] == "spec/models/f_spec.rb" }
      window = body["directory_runtime_window_file_growth"]["rows"].find { it["path"] == "spec/models/f_spec.rb" }

      expect(push["change"]).to eq(50.0)
      expect(window["change"]).to eq(50.0)
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "read only the two ends", behavior: "rewriting the middle run's durations leaves the endpoint answer byte-identical", layer: "request" }
    it "is unchanged when the middle run changes (two-endpoint contract)" do
      before_block = blocks.last
      TestRun.find_by!(commit_sha: "middle000001").spec_observations.update_all(duration_seconds: 900.0)

      expect(blocks.last).to eq(before_block)
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "sum to the area row", behavior: "when not truncated the files' changes sum to the area's directory_runtime_window_growth change", layer: "request" }
    it "sums to the area's window change" do
      body = get_repository(query: { branch: "main", spec_directory: area })
      area_row = body["directory_runtime_window_growth"]["rows"].find { it["path"] == area }

      expect(body["directory_runtime_window_file_growth"]["rows"].sum { it["change"] })
        .to be_within(0.001).of(area_row["change"])
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "share the baseline walk", behavior: "the file window block names the same baseline commit, anchor commit and runs_back as directory_runtime_window_growth_window", layer: "request" }
    it "names the same baseline as the area time window" do
      body = get_repository(query: { branch: "main", spec_directory: area })
      keys = %w[baseline_commit_sha anchor_commit_sha runs_back state]

      expect(body["directory_runtime_window_file_growth_window"].slice(*keys))
        .to eq(body["directory_runtime_window_growth_window"].slice(*keys))
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "bound its reads", behavior: "a comparable window with an area adds exactly one spec_observations read over the same request with the file presenter stubbed out", layer: "request" }
    it "adds exactly one observation read when comparable and asked" do
      with_block = observation_read_count
      allow(SpecDirectoryWindowFileRuntimeGrowth).to receive(:for).and_return(nil)
      without_block = observation_read_count

      expect(with_block - without_block).to eq(1)
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "be null without an area or a branch", behavior: "no ?spec_directory= or no ?branch= serves a null block, grouped false and issues no file read", layer: "request" }
    it "serves null without an area or without a branch, adding no read" do
      no_area_window, no_area_block = blocks(query: { branch: "main" })
      no_branch_window, no_branch_block = blocks(query: { spec_directory: area })

      expect([no_area_block, no_branch_block]).to eq([nil, nil])
      expect(no_area_window).to include("path" => nil, "grouped" => false, "state" => nil, "comparable" => false,
                                        "baseline_commit_sha" => nil, "runs_back" => nil)
      expect(no_branch_window).to include("path" => area, "grouped" => false, "state" => nil,
                                          "branch_scope" => "all_branches")
      allow(SpecDirectoryWindowFileRuntimeGrowth).to receive(:for).and_call_original
      get_repository(query: { branch: "main" })
      get_repository(query: { spec_directory: area })
      expect(SpecDirectoryWindowFileRuntimeGrowth).not_to have_received(:for)
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "sit beside directory_runtime_file_growth", behavior: "the pair is top-level, directly after directory_runtime_file_growth, and absent from latest_run", layer: "request" }
    it "is top-level and ordered after directory_runtime_file_growth" do
      body = get_repository(query: { branch: "main", spec_directory: area })
      keys = body.keys

      expect(keys.index("directory_runtime_window_file_growth_window")).to eq(keys.index("directory_runtime_file_growth") + 1)
      expect(body["latest_run"]).not_to have_key("directory_runtime_window_file_growth")
    end
  end

  describe "a mid-window excursion" do
    # @intent: { entity: "directory_runtime_window_file_growth", action: "compare two ends, not a series", behavior: "a file that rises in the middle run and falls back reads change 0", layer: "request" }
    it "reads change 0" do
      ingest(timed_files("spec/models/f_spec.rb" => { seconds: [10.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/f_spec.rb" => { seconds: [300.0] }), commit_sha: "middle000001", at: 20.days.ago)
      ingest(timed_files("spec/models/f_spec.rb" => { seconds: [10.0] }), commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks

      expect(block["rows"].first).to include("change" => 0.0, "moved" => false)
    end
  end

  describe "?layer=" do
    before do
      ingest(timed_files("spec/models/a_spec.rb" => { layer: "request", seconds: [2.0] },
                         "spec/models/u_spec.rb" => { layer: "unit", seconds: [3.0] }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/a_spec.rb" => { layer: "request", seconds: [12.0] },
                         "spec/models/u_spec.rb" => { layer: "unit", seconds: [9.0] }),
             commit_sha: "anchor000001", at: 10.days.ago)
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "narrow to a declared layer", behavior: "?layer=request lists only request files, echoes the layer on both blocks and narrows the four denominators", layer: "request" }
    it "narrows rows and denominators and echoes the layer" do
      window, block = blocks(query: { branch: "main", spec_directory: area, layer: "request" })

      expect(window["layer"]).to eq("request")
      expect(block["layer"]).to eq("request")
      expect(block["rows"].map { it["path"] }).to eq(["spec/models/a_spec.rb"])
      expect(block["rows"].first["change"]).to eq(10.0)
      expect(block["file_count"]).to eq(1)
      expect([block["baseline_recorded_count"], block["anchor_recorded_count"],
              block["baseline_timed_count"], block["anchor_timed_count"]]).to eq([1, 1, 1, 1])
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "leave the unasked body unmarked", behavior: "an unasked or malformed layer serves the unnarrowed body with no layer key, byte-identical", layer: "request" }
    it "reads a malformed layer as no ask, with no layer key" do
      window, block = blocks
      expect(window).not_to have_key("layer")
      expect(block).not_to have_key("layer")
      expect(blocks(query: { branch: "main", spec_directory: area, layer: "bogus" })).to eq([window, block])
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "name new files for a layer the baseline lacked", behavior: "?layer=system with system examples only at the anchor is comparable with every row new_file true and change null", layer: "system" }
    it "serves a layer present at the anchor only as new_file rows" do
      ingest(timed_files("spec/models/a_spec.rb" => { layer: "request", seconds: [2.0] }), commit_sha: "baseline0002", at: 31.days.ago)
      TestRun.where(commit_sha: "anchor000001").destroy_all
      ingest(timed_files("spec/models/a_spec.rb" => { layer: "request", seconds: [2.0] },
                         "spec/models/s_spec.rb" => { layer: "system", seconds: [4.0] }),
             commit_sha: "anchor000002", at: 10.days.ago)

      window, block = blocks(query: { branch: "main", spec_directory: area, layer: "system" })

      expect(window).to include("state" => "comparable", "layer" => "system")
      expect(block["rows"]).to eq([{ "path" => "spec/models/s_spec.rb", "baseline_seconds" => nil,
                                     "anchor_seconds" => 4.0, "change" => nil, "comparable" => false,
                                     "moved" => false, "new_file" => true, "removed_file" => false,
                                     "timing_gap" => false }])
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "answer a layer empty at both ends", behavior: "a layer neither end declared is comparable with no rows, file_count 0 and the layer echoed", layer: "system" }
    it "is comparable with no rows for a layer neither end has" do
      window, block = blocks(query: { branch: "main", spec_directory: area, layer: "system" })

      expect(window).to include("state" => "comparable", "layer" => "system")
      expect(block).to include("rows" => [], "file_count" => 0, "truncated" => false, "layer" => "system")
    end
  end

  describe "a file timed at one end only" do
    # @intent: { entity: "directory_runtime_window_file_growth", action: "never difference against zero", behavior: "a file whose baseline examples were untimed serves change null and timing_gap true, distinct from a new file and a removed file, listed after timed files", layer: "request" }
    it "serves timing_gap, distinct from new_file and removed_file" do
      ingest(timed_files("spec/models/gap_spec.rb" => { seconds: [nil] }, "spec/models/gone_spec.rb" => { seconds: [4.0] },
                         "spec/models/timed_spec.rb" => { seconds: [1.0] }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/gap_spec.rb" => { seconds: [9.0] }, "spec/models/fresh_spec.rb" => { seconds: [5.0] },
                         "spec/models/timed_spec.rb" => { seconds: [4.0] }),
             commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks
      rows = block["rows"].index_by { it["path"] }

      expect(block["rows"].first["path"]).to eq("spec/models/timed_spec.rb")
      expect(rows["spec/models/gap_spec.rb"]).to include("baseline_seconds" => nil, "anchor_seconds" => 9.0,
                                                         "change" => nil, "timing_gap" => true,
                                                         "new_file" => false, "removed_file" => false)
      expect(rows["spec/models/fresh_spec.rb"]).to include("new_file" => true, "timing_gap" => false)
      expect(rows["spec/models/gone_spec.rb"]).to include("removed_file" => true, "timing_gap" => false)
    end
  end

  describe "every non-comparable parent state" do
    def expect_withheld(state, query: { branch: "main", spec_directory: area }, reads: 0)
      window, block = blocks(query: query)

      expect(window).to include("state" => state, "comparable" => false, "grouped" => true, "path" => area)
      expect(block).to be_nil
      expect(file_window_reads(query: query)).to eq(reads)
    end

    # The file-grain read adds exactly its own observation read on top of the request, so counting it
    # as a difference against the same request with the file presenter stubbed out isolates it.
    def file_window_reads(query:)
      with_block = observation_read_count(query: query)
      allow(SpecDirectoryWindowFileRuntimeGrowth).to receive(:for).and_return(nil)
      with_block - observation_read_count(query: query)
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold with no baseline rows", behavior: "a baseline that wrote no per-example rows serves baseline_unrecorded and a null block with zero file reads", layer: "request" }
    it "serves baseline_unrecorded" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [1.0] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("baseline_unrecorded")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold from a totals-only anchor", behavior: "an anchor that wrote no per-example rows serves anchor_unrecorded and a null block with zero file reads", layer: "request" }
    it "serves anchor_unrecorded" do
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [1.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("anchor_unrecorded")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold when neither end recorded", behavior: "two totals-only ends serve neither_recorded and a null block", layer: "request" }
    it "serves neither_recorded" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("neither_recorded")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold an untimed baseline", behavior: "a baseline whose examples were all untimed serves baseline_untimed, inherited from the parent, with zero file reads", layer: "request" }
    it "serves baseline_untimed" do
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [nil] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [2.0] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("baseline_untimed")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold an untimed anchor", behavior: "an anchor whose examples were all untimed serves anchor_untimed with zero file reads", layer: "request" }
    it "serves anchor_untimed" do
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [2.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [nil] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("anchor_untimed")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold when neither end was timed", behavior: "two untimed ends serve neither_timed with zero file reads", layer: "request" }
    it "serves neither_timed" do
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [nil] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [nil] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("neither_timed")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold before reading", behavior: "a window of one run serves no_earlier_run with null shas and runs_back and zero file reads", layer: "request" }
    it "serves no_earlier_run" do
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [1.0] }), commit_sha: "only00000001", at: 1.day.ago)

      window, = blocks
      expect(window.values_at("baseline_commit_sha", "runs_back")).to eq([nil, nil])
      expect(window["anchor_commit_sha"]).to eq("only00000001")
      expect_withheld("no_earlier_run")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold before reading", behavior: "an anchor that reported no tests serves anchor_unmeasured with zero file reads", layer: "request" }
    it "serves anchor_unmeasured" do
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [1.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 0)

      expect_withheld("anchor_unmeasured")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold before reading", behavior: "earlier runs that all reported no tests serve no_measured_baseline with zero file reads", layer: "request" }
    it "serves no_measured_baseline" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 0)
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [1.0] }), commit_sha: "anchor000001", at: 10.days.ago)

      expect_withheld("no_measured_baseline")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "withhold before reading", behavior: "earlier runs assembled differently serve no_comparable_composition with zero file reads", layer: "request" }
    it "serves no_comparable_composition" do
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [1.0] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [1.0] }), commit_sha: "anchor000001", at: 10.days.ago)
      allow_any_instance_of(TestRun).to receive(:assembled_like?).and_return(false) # rubocop:disable RSpec/AnyInstance

      expect_withheld("no_comparable_composition")
    end

    # @intent: { entity: "directory_runtime_window_file_growth", action: "carry the layer into a refusal", behavior: "a layered request refused by the walk still echoes the layer on the window block while the block is null", layer: "request" }
    it "echoes the layer on a refused window" do
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [1.0] }), commit_sha: "only00000001", at: 1.day.ago)

      window, block = blocks(query: { branch: "main", spec_directory: area, layer: "request" })

      expect(block).to be_nil
      expect(window).to include("state" => "no_earlier_run", "layer" => "request")
    end
  end

  describe "the panels" do
    def page = Capybara.string(response.body)

    def panel = page.find("#spec-directory-window-file-runtime-growth")

    def panel_text = panel.text.gsub(/\s+/, " ").strip

    # @intent: { entity: "GET /repositories/:id", action: "link the window time area row to its files", behavior: "each area row of the window time panel carries a primary Which files got slower or faster across the window action to ?spec_directory= carrying the branch, ending in #changes", layer: "request" }
    it "gives each window time area row a drill-in to its files" do
      window_with_f

      get repository_path(repository, branch: "main")

      row = page.find("#spec-directory-window-runtime-growth tbody tr", text: area)
      action = row.find("a", exact_text: "Which files got slower or faster across the window", visible: :all)

      expect(row).to have_css("button.row-open", text: area)
      expect(action[:href]).to include("spec_directory=spec%2Fmodels").and include("branch=main")
      expect(action[:href]).to end_with("#changes")
    end

    # @intent: { entity: "GET /repositories/:id", action: "mark the open area", behavior: "the opened area's row carries aria-current and the drawer is titled with the area", layer: "request" }
    it "marks the opened area row current" do
      window_with_f

      get repository_path(repository, branch: "main", spec_directory: area)

      row = page.find("#spec-directory-window-runtime-growth tbody tr", text: area)
      expect(row).to have_css("button.row-open[aria-current='true']")
      expect(page.find(".rc-drawer-title").text).to eq(area)
    end

    # @intent: { entity: "GET /repositories/:id", action: "render the window file time panel", behavior: "the opened area lists f_spec.rb first with +50s, titled as the window's two ends compared and not a trend, naming the baseline and runs_back", layer: "request" }
    it "lists the file that got slower, worded as the window's two ends" do
      window_with_f

      get repository_path(repository, branch: "main", spec_directory: area)

      expect(panel).to have_text("Files that got slower or faster across the window")
      expect(panel_text).to include("not a trend")
      expect(panel.all("tbody tr").first.all("td").first.text.strip).to eq("spec/models/f_spec.rb")
      expect(panel_text).to include("+#{SpecObservation.humanized_duration(50.0)}")
      expect(panel_text).to include("Measured against baselin").and include("2 runs back in this window")
      expect(panel_text).to include("Only the two ends are compared").and include("never the run wall clock")
      expect(page.all("#spec-directory-window-file-runtime-growth-clear-layer")).to be_empty
    end

    # @intent: { entity: "GET /repositories/:id", action: "render three absences distinctly", behavior: "the panel reads New file, File removed and Not timed in separate rows and an untimed side as not reported, never 0.00s", layer: "request" }
    it "renders new, removed and untimed files distinctly" do
      ingest(timed_files("spec/models/gap_spec.rb" => { seconds: [nil] }, "spec/models/gone_spec.rb" => { seconds: [4.0] }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/gap_spec.rb" => { seconds: [9.0] }, "spec/models/fresh_spec.rb" => { seconds: [5.0] }),
             commit_sha: "anchor000001", at: 10.days.ago)

      get repository_path(repository, branch: "main", spec_directory: area)

      rows = panel.all("tbody tr").to_h { [it.all("td").first.text.strip, it.text.gsub(/\s+/, " ")] }
      expect(rows["spec/models/fresh_spec.rb"]).to include("New file")
      expect(rows["spec/models/gone_spec.rb"]).to include("File removed")
      expect(rows["spec/models/gap_spec.rb"]).to include("Not timed").and include("not reported")
      expect(rows["spec/models/gap_spec.rb"]).not_to include("0.00s")
    end

    # @intent: { entity: "GET /repositories/:id", action: "narrow the file time panel", behavior: "?layer=request states the layer once with a clear link and words the denominators as request-layer rows", layer: "request" }
    it "narrows under ?layer= and states the layer once" do
      ingest(timed_files("spec/models/a_spec.rb" => { layer: "request", seconds: [2.0] },
                         "spec/models/u_spec.rb" => { layer: "unit", seconds: [3.0] }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/a_spec.rb" => { layer: "request", seconds: [12.0] },
                         "spec/models/u_spec.rb" => { layer: "unit", seconds: [9.0] }),
             commit_sha: "anchor000001", at: 10.days.ago)

      get repository_path(repository, branch: "main", spec_directory: area, layer: "request")

      expect(panel.all("tbody tr").map { it.all("td").first.text.strip }).to eq(["spec/models/a_spec.rb"])
      expect(panel_text).to include("Only the request-layer examples").and include("request-layer example rows")
      expect(page.all("#spec-directory-window-file-runtime-growth-clear-layer").size).to eq(1)
    end

    # @intent: { entity: "GET /repositories/:id", action: "word comparable but unmoved", behavior: "two ends with identical file times render the no-file-changed-pace state", layer: "request" }
    it "renders the unmoved state" do
      2.times do |index|
        ingest(timed_files("spec/models/a_spec.rb" => { seconds: [3.0] }), commit_sha: "same0000000#{index}", at: (30 - (index * 20)).days.ago)
      end

      get repository_path(repository, branch: "main", spec_directory: area)

      expect(panel_text).to include("No file changed pace across this window").and include("Only those two ends were compared")
    end

    # @intent: { entity: "GET /repositories/:id", action: "render a layer-empty state", behavior: "a layer neither end declared renders the layer-empty state naming the area", layer: "system" }
    it "renders the layer-empty state" do
      window_with_f

      get repository_path(repository, branch: "main", spec_directory: area, layer: "system")

      expect(panel_text).to include("No system-layer examples in this directory")
      expect(panel.all("tbody tr")).to be_empty
    end

    # @intent: { entity: "GET /repositories/:id", action: "be absent when the parent refuses", behavior: "a refused window (untimed baseline) renders no file time panel even with ?spec_directory= set", layer: "request" }
    it "renders no panel when the parent window is not comparable" do
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [nil] }), commit_sha: "baseline0001", at: 30.days.ago)
      ingest(timed_files("spec/models/a_spec.rb" => { seconds: [2.0] }), commit_sha: "anchor000001", at: 10.days.ago)

      get repository_path(repository, branch: "main", spec_directory: area)

      expect(page.all("#spec-directory-window-file-runtime-growth")).to be_empty
    end
  end
end
