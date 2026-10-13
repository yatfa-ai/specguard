# frozen_string_literal: true

require "rails_helper"

# The `directory_file_growth` pair on `GET /api/v1/repository?branch=&spec_directory=` and the "Files
# that grew or shrank across the window" panel of repositories#show (SPGD-1794) — which spec FILES of
# one area moved across the branch window's two ENDPOINTS. Both are built from one
# `SpecDirectoryWindowFileGrowth`, off the window parent `directory_growth` is built from, so they are
# asserted off one fixture.
RSpec.describe "GET /api/v1/repository — directory_file_growth", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def get_repository(query: {})
    token = repository.api_keys.create!.raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  def blocks(query: { branch: "main", spec_directory: "spec/models" })
    body = get_repository(query: query)
    [body["directory_file_growth_window"], body["directory_file_growth"]]
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

  # `files` is `{ "spec/models/a_spec.rb" => { count: 10, layer: "request" }, ... }`.
  def examples(files)
    files.flat_map do |file, config|
      Array.new(config.fetch(:count)) do |index|
        name = "#{file} #{index + 1}"
        if (layer = config[:layer])
          annotated_spec(file_path: file, line_number: index + 1, layer: layer, name: name)
        else
          unannotated_spec(file_path: file, line_number: index + 1, name: name)
        end
      end
    end
  end

  # a_spec.rb: 10 examples at the baseline, 10 in the middle run, 20 at the newest; everything else is
  # unchanged. So the last push reads 0 for a_spec.rb and the window reads +10.
  def three_run_window
    [["baseline0001", 30.days.ago, 10], ["middle000001", 20.days.ago, 10], ["anchor000001", 10.days.ago, 20]]
      .each do |sha, at, count|
      ingest(examples("spec/models/a_spec.rb" => { count: count, layer: "request" },
                      "spec/models/b_spec.rb" => { count: 4 },
                      "spec/jobs/c_spec.rb" => { count: 3 }),
             commit_sha: sha, at: at)
    end
  end

  def observation_read_count(query:) = observation_reads { get_repository(query: query) }.length

  describe "a window whose file grew across several pushes" do
    before { three_run_window }

    # @intent: { entity: "directory_file_growth", action: "rank the file that grew across the window", behavior: "a_spec.rb ranks first with baseline 10, anchor 20, change 10 where directory_run_file_growth reads change 0, the block keys in the documented order", layer: "request" }
    it "ranks the file first with the endpoint change, where the last-push block reads 0" do
      body = get_repository(query: { branch: "main", spec_directory: "spec/models" })
      window = body["directory_file_growth_window"]
      block = body["directory_file_growth"]

      expect(window).to eq("path" => "spec/models", "order" => "abs_change_desc,path_asc", "tie_break_served" => true,
                           "basis" => "two_endpoints", "branch_scope" => "single_branch", "branch" => "main",
                           "grouped" => true, "state" => "comparable", "comparable" => true,
                           "anchor_commit_sha" => "anchor000001", "baseline_commit_sha" => "baseline0001",
                           "runs_back" => 2, "limit" => SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT)
      expect(block.keys).to eq(%w[rows file_count truncated baseline_recorded_count anchor_recorded_count])
      expect(block["rows"].first).to eq("path" => "spec/models/a_spec.rb", "baseline_count" => 10,
                                        "anchor_count" => 20, "change" => 10, "moved" => true,
                                        "new_file" => false, "removed_file" => false)
      expect(block["rows"].last["change"]).to eq(0)
      expect([block["file_count"], block["truncated"], block["baseline_recorded_count"],
              block["anchor_recorded_count"]]).to eq([2, false, 14, 24])

      push = body["directory_run_file_growth"]["rows"].find { it["path"] == "spec/models/a_spec.rb" }
      expect(push["change"]).to eq(10)
    end

    # @intent: { entity: "directory_file_growth", action: "read only the two ends", behavior: "deleting the middle run's rows leaves the window block byte-identical", layer: "request" }
    it "is unchanged when the middle run is rewritten (two-endpoint contract)" do
      before_block = blocks.last
      TestRun.find_by!(commit_sha: "middle000001").spec_observations.destroy_all

      expect(blocks.last).to eq(before_block)
    end

    # @intent: { entity: "directory_file_growth", action: "sum to the area", behavior: "when the area is not truncated the file changes sum to the area's directory_growth row change", layer: "request" }
    it "sums to the area's directory_growth change" do
      body = get_repository(query: { branch: "main", spec_directory: "spec/models" })
      area = body["directory_growth"]["rows"].find { it["path"] == "spec/models" }

      expect(body["directory_file_growth"]["truncated"]).to be(false)
      expect(body["directory_file_growth"]["rows"].sum { it["change"] }).to eq(area["change"])
      expect(area["change"]).to eq(10)
    end

    # @intent: { entity: "directory_file_growth", action: "share the baseline walk", behavior: "baseline_commit_sha, anchor_commit_sha and runs_back equal directory_growth's", layer: "request" }
    it "names the same baseline as directory_growth" do
      body = get_repository(query: { branch: "main", spec_directory: "spec/models" })
      keys = %w[baseline_commit_sha anchor_commit_sha runs_back]

      expect(body["directory_file_growth_window"].slice(*keys)).to eq(body["directory_growth"].slice(*keys))
    end

    # @intent: { entity: "directory_file_growth", action: "sit beside directory_run_file_growth", behavior: "the pair is top-level, directly after directory_run_file_growth, and absent from latest_run", layer: "request" }
    it "is top-level and ordered beside directory_run_file_growth" do
      body = get_repository(query: { branch: "main", spec_directory: "spec/models" })
      keys = body.keys

      expect(keys.index("directory_file_growth_window")).to eq(keys.index("directory_run_file_growth") + 1)
      expect(body["latest_run"]).not_to have_key("directory_file_growth")
    end
  end

  describe "when it is not asked for" do
    before { three_run_window }

    # @intent: { entity: "directory_file_growth", action: "be null without an area", behavior: "with ?branch= and no ?spec_directory= the block is null, grouped false, path null, and no read is added", layer: "request" }
    it "serves null with no area, adding no observation read" do
      window, block = blocks(query: { branch: "main" })

      expect(block).to be_nil
      expect(window).to include("path" => nil, "grouped" => false, "state" => nil, "comparable" => false,
                                "anchor_commit_sha" => nil, "baseline_commit_sha" => nil, "runs_back" => nil,
                                "branch" => "main", "branch_scope" => "single_branch")
      allow(SpecDirectoryWindowFileGrowth).to receive(:for).and_call_original
      get_repository(query: { branch: "main" })
      expect(SpecDirectoryWindowFileGrowth).not_to have_received(:for)
    end

    # @intent: { entity: "directory_file_growth", action: "be null without a branch", behavior: "with ?spec_directory= and no ?branch= the block is null, grouped false and branch_scope all_branches", layer: "request" }
    it "serves null without ?branch=" do
      window, block = blocks(query: { spec_directory: "spec/models" })

      expect(block).to be_nil
      expect(window).to include("path" => "spec/models", "grouped" => false, "state" => nil,
                                "branch_scope" => "all_branches", "branch" => nil)
    end

    # @intent: { entity: "directory_file_growth", action: "bound its reads", behavior: "asked and comparable adds exactly one spec_observations read over the presenter stubbed out; comparable and unasked adds none", layer: "request" }
    it "adds exactly one read when asked and comparable, none when unasked" do
      asked = { branch: "main", spec_directory: "spec/models" }
      with_block = observation_read_count(query: asked)
      allow(SpecDirectoryWindowFileGrowth).to receive(:for).and_return(nil)
      without_block = observation_read_count(query: asked)

      expect(with_block - without_block).to eq(1)
      expect(observation_read_count(query: { branch: "main" })).to eq(observation_read_count(query: { branch: "main" }))
    end
  end

  describe "files present at one end only" do
    # @intent: { entity: "directory_file_growth", action: "name a file present at one end only", behavior: "a file only at the anchor is new_file true and one only at the baseline is removed_file true", layer: "unit" }
    it "serves new_file and removed_file" do
      ingest(examples("spec/models/old_spec.rb" => { count: 3 }, "spec/models/keep_spec.rb" => { count: 2 }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(examples("spec/models/new_spec.rb" => { count: 4 }, "spec/models/keep_spec.rb" => { count: 2 }),
             commit_sha: "anchor000001", at: 10.days.ago)

      _window, block = blocks
      rows = block["rows"].index_by { it["path"] }

      expect(rows.fetch("spec/models/new_spec.rb")).to include("new_file" => true, "removed_file" => false,
                                                              "baseline_count" => 0, "anchor_count" => 4)
      expect(rows.fetch("spec/models/old_spec.rb")).to include("new_file" => false, "removed_file" => true,
                                                              "baseline_count" => 3, "anchor_count" => 0)
    end
  end

  describe "?layer=" do
    before do
      ingest(examples("spec/models/a_spec.rb" => { count: 2, layer: "request" },
                      "spec/models/u_spec.rb" => { count: 5, layer: "unit" }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(examples("spec/models/a_spec.rb" => { count: 6, layer: "request" },
                      "spec/models/u_spec.rb" => { count: 5, layer: "unit" }),
             commit_sha: "anchor000001", at: 10.days.ago)
    end

    # @intent: { entity: "directory_file_growth", action: "narrow to a declared layer", behavior: "?layer=request lists only request examples, echoes the layer on both blocks, and the file changes sum to the layer-narrowed directory_growth row", layer: "request" }
    it "narrows, echoes the layer and sums to the layer-narrowed area row" do
      body = get_repository(query: { branch: "main", spec_directory: "spec/models", layer: "request" })
      window = body["directory_file_growth_window"]
      block = body["directory_file_growth"]
      area = body["directory_growth"]["rows"].find { it["path"] == "spec/models" }

      expect(window["layer"]).to eq("request")
      expect(block["layer"]).to eq("request")
      expect(block["rows"].map { it["path"] }).to eq(["spec/models/a_spec.rb"])
      expect(block["rows"].sum { it["change"] }).to eq(area["change"])
      expect(area["change"]).to eq(4)
      expect([block["baseline_recorded_count"], block["anchor_recorded_count"]]).to eq([2, 6])
    end

    # @intent: { entity: "directory_file_growth", action: "echo no layer when none was asked", behavior: "the unasked body has no layer key on either block, and a bogus layer reads as no ask", layer: "request" }
    it "echoes no layer when unasked and reads a bogus layer as no ask" do
      window, block = blocks

      expect(window).not_to have_key("layer")
      expect(block).not_to have_key("layer")
      expect(blocks(query: { branch: "main", spec_directory: "spec/models", layer: "bogus" })).to eq([window, block])
    end

    # @intent: { entity: "directory_file_growth", action: "carry the layer into a refusal", behavior: "a layered request whose baseline recorded no examples echoes the layer on the window block while the block is null", layer: "request" }
    it "echoes the layer on a refused window" do
      repository.test_runs.destroy_all
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest(examples("spec/models/a_spec.rb" => { count: 6, layer: "request" }), commit_sha: "anchor000001",
                                                                                   at: 10.days.ago)

      window, block = blocks(query: { branch: "main", spec_directory: "spec/models", layer: "request" })

      expect(block).to be_nil
      expect(window).to include("state" => "baseline_unrecorded", "layer" => "request", "comparable" => false)
    end
  end

  describe "every non-comparable state" do
    def expect_withheld(state, reads: 0)
      query = { branch: "main", spec_directory: "spec/models" }
      window, block = blocks(query: query)

      expect(window).to include("state" => state, "comparable" => false, "grouped" => true,
                                "path" => "spec/models")
      expect(block).to be_nil
      expect(file_window_reads(query)).to eq(reads)
    end

    # The file-grain window read is `file_growth_between` handed the window's ends, counted as a
    # difference against the same request with the presenter stubbed out.
    def file_window_reads(query)
      with_block = observation_read_count(query: query)
      allow(SpecDirectoryWindowFileGrowth).to receive(:for).and_return(nil)
      with_block - observation_read_count(query: query)
    end

    def seed(commit_sha, at, count: 1, total: nil)
      ingest(examples("spec/models/a_spec.rb" => { count: count }), commit_sha: commit_sha, at: at, total: total)
    end

    # @intent: { entity: "directory_file_growth", action: "withhold from a baseline with no rows", behavior: "a baseline run that wrote no per-example rows serves baseline_unrecorded, a null block, and no file read", layer: "unit" }
    it "serves baseline_unrecorded without a file read" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      seed("anchor000001", 10.days.ago)

      expect_withheld("baseline_unrecorded")
    end

    # @intent: { entity: "directory_file_growth", action: "withhold from an anchor with no rows", behavior: "an anchor that wrote no per-example rows serves anchor_unrecorded, a null block, and no file read", layer: "unit" }
    it "serves anchor_unrecorded without a file read" do
      seed("baseline0001", 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("anchor_unrecorded")
    end

    # @intent: { entity: "directory_file_growth", action: "withhold when neither end recorded", behavior: "two totals-only ends serve neither_recorded, a null block, and no file read", layer: "unit" }
    it "serves neither_recorded without a file read" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 10)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 10)

      expect_withheld("neither_recorded")
    end

    # @intent: { entity: "directory_file_growth", action: "withhold before reading", behavior: "a window of one run serves no_earlier_run with null shas and issues no file read", layer: "unit" }
    it "serves no_earlier_run, reading nothing" do
      seed("only00000001", 1.day.ago)

      window, = blocks
      expect(window.values_at("baseline_commit_sha", "runs_back")).to eq([nil, nil])
      expect(window["anchor_commit_sha"]).to eq("only00000001")
      expect_withheld("no_earlier_run")
    end

    # @intent: { entity: "directory_file_growth", action: "withhold before reading", behavior: "an anchor that reported no tests serves anchor_unmeasured and issues no file read", layer: "unit" }
    it "serves anchor_unmeasured, reading nothing" do
      seed("baseline0001", 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 0)

      expect_withheld("anchor_unmeasured")
    end

    # @intent: { entity: "directory_file_growth", action: "withhold before reading", behavior: "earlier runs that all reported no tests serve no_measured_baseline and issue no file read", layer: "unit" }
    it "serves no_measured_baseline, reading nothing" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 0)
      seed("anchor000001", 10.days.ago)

      expect_withheld("no_measured_baseline")
    end

    # @intent: { entity: "directory_file_growth", action: "withhold before reading", behavior: "earlier runs assembled differently serve no_comparable_composition and issue no file read", layer: "unit" }
    it "serves no_comparable_composition, reading nothing" do
      seed("baseline0001", 30.days.ago)
      seed("anchor000001", 10.days.ago)
      allow_any_instance_of(TestRun).to receive(:assembled_like?).and_return(false) # rubocop:disable RSpec/AnyInstance

      expect_withheld("no_comparable_composition")
    end
  end

  describe "the panel" do
    def page = Capybara.string(response.body)

    def panel = page.find("#spec-directory-window-file-growth")

    def panel_text = panel.text.gsub(/\s+/, " ").strip

    # @intent: { entity: "GET /repositories/:id", action: "link the window area row to its files", behavior: "each area row of the window panel carries a primary Which files moved across the window action to ?spec_directory= carrying the branch", layer: "request" }
    it "gives each window area row a drill-in to its files" do
      three_run_window

      get repository_path(repository, branch: "main")

      row = page.find("#spec-directory-window-growth tbody tr", text: "spec/models")
      action = row.find("a", exact_text: "Which files moved across the window", visible: :all)

      expect(row).to have_css("button.row-open", text: "spec/models")
      expect(action[:href]).to include("spec_directory=spec%2Fmodels").and include("branch=main")
      expect(action[:href]).to end_with("#changes")
    end

    # @intent: { entity: "GET /repositories/:id", action: "render the window file panel", behavior: "the opened area lists a_spec.rb first with +10, titled as the window's two ends compared and not a trend, naming the baseline and runs_back", layer: "request" }
    it "lists the file that grew, worded as the window's two ends" do
      three_run_window

      get repository_path(repository, branch: "main", spec_directory: "spec/models")

      expect(page).to have_css("#spec-directory-window-file-growth")
      expect(panel).to have_text("Files that grew or shrank across the window")
      expect(panel_text).to include("not a trend")
      expect(panel.all("tbody tr").first.all("td").first.text.strip).to eq("spec/models/a_spec.rb")
      expect(panel_text).to include("+10")
      expect(panel_text).to include("Measured against baselin").and include("2 runs back in this window")
      expect(panel_text).to include("Only the two ends are compared")
      expect(page).to have_css("#spec-directory-file-growth")
      expect(page.all("#spec-directory-window-file-growth-clear-layer")).to be_empty
    end

    # @intent: { entity: "GET /repositories/:id", action: "narrow the window file panel", behavior: "?layer=request states the layer once with a clear link and words the denominators as request-layer rows", layer: "request" }
    it "narrows under ?layer=" do
      ingest(examples("spec/models/a_spec.rb" => { count: 2, layer: "request" }, "spec/models/u_spec.rb" => { count: 5, layer: "unit" }),
             commit_sha: "baseline0001", at: 30.days.ago)
      ingest(examples("spec/models/a_spec.rb" => { count: 6, layer: "request" }, "spec/models/u_spec.rb" => { count: 5, layer: "unit" }),
             commit_sha: "anchor000001", at: 10.days.ago)

      get repository_path(repository, branch: "main", spec_directory: "spec/models", layer: "request")

      expect(panel.all("tbody tr").map { it.all("td").first.text.strip }).to eq(["spec/models/a_spec.rb"])
      expect(panel_text).to include("Only the request-layer examples").and include("at both ends of this window")
      expect(panel_text).to include("request-layer example rows")
      expect(page.all("#spec-directory-window-file-growth-clear-layer").size).to eq(1)
    end

    # @intent: { entity: "GET /repositories/:id", action: "word a window where no file moved", behavior: "two ends with identical file counts render the no-file-moved state naming only the two ends were compared", layer: "request" }
    it "renders the unmoved state" do
      2.times do |index|
        ingest(examples("spec/models/a_spec.rb" => { count: 3 }), commit_sha: "same0000000#{index}",
                                                                   at: (30 - (index * 20)).days.ago)
      end

      get repository_path(repository, branch: "main", spec_directory: "spec/models")

      expect(panel_text).to include("No file moved across this window").and include("Only those two ends were compared")
    end

    # @intent: { entity: "GET /repositories/:id", action: "render nothing the window refuses", behavior: "a window of one run renders no window file panel even with an area asked", layer: "request" }
    it "renders nothing when the window parent cannot compare" do
      ingest(examples("spec/models/a_spec.rb" => { count: 3 }), commit_sha: "only00000001", at: 1.day.ago)

      get repository_path(repository, branch: "main", spec_directory: "spec/models")

      expect(page.all("#spec-directory-window-file-growth")).to be_empty
    end

    # @intent: { entity: "GET /repositories/:id", action: "read the one object the API reads", behavior: "the panel rows equal the API rows for the same request, path for path and change for change", layer: "request" }
    it "lists exactly the files the API serves" do
      three_run_window
      api_rows = blocks.last["rows"]

      get repository_path(repository, branch: "main", spec_directory: "spec/models")

      expect(panel.all("tbody tr").map { it.all("td").first.text.strip }).to eq(api_rows.map { it["path"] })
      expect(panel.all("tbody tr").map { it.all("td")[3]["data-sort"].to_i }).to eq(api_rows.map { it["change"] })
    end
  end
end
