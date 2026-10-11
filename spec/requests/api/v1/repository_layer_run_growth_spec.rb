# frozen_string_literal: true

require "rails_helper"

# The `layer_run_growth` pair on `GET /api/v1/repository` and the delta line under the Overview's
# "Declared layers" row — how the run-wide DECLARED-LAYER MIX moved against the previous run on the
# same branch. Both are built from one `LayerRunGrowth`, so they are asserted off the same fixture.
#
# Rows are written by `Ingest::RunRecorder` (never inserted by hand), so every state is one the
# recorder produces from what a real client sends.
RSpec.describe "GET /api/v1/repository — layer_run_growth", type: :request do
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
    [body["layer_run_growth_window"], body["layer_run_growth"]]
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

  # `{"unit" => 2, "request" => 1, "undeclared" => 2}` as that many examples, each in its own file.
  # The file lives under spec/models whatever the layer — the path is never consulted.
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

  def comparable_runs(repo: repository, branch: "main")
    ingest(mix("unit" => 2, "request" => 1, "undeclared" => 2), commit_sha: "previous0001", at: 20.days.ago,
                                                                repo: repo, branch: branch)
    ingest(mix("unit" => 2, "request" => 41), commit_sha: "latest000001", at: 10.days.ago, repo: repo,
                                              branch: branch)
  end

  def run_layer_reads(&) = run_layer_mix_reads(&).length

  describe "two comparable runs on a branch" do
    before { comparable_runs }

    # @intent: { entity: "layer_run_growth", action: "serve the mix movement", behavior: "previous unit 2 request 1 undeclared 2 against latest unit 2 request 41 undeclared 0 serves request baseline 1 anchor 41 change 40, an unmoved layer as a measured zero and every layer in the closed enum order", layer: "request" }
    it "serves per-layer baseline, anchor and change in the closed enum order" do
      window, block = blocks

      expect(window).to include("basis" => "previous_run_on_branch", "branch" => "main", "state" => "comparable",
                                "comparable" => true, "anchor_commit_sha" => "latest000001",
                                "baseline_commit_sha" => "previous0001")
      expect(block["layers"].keys).to eq(layers)
      expect(block["layers"]["request"]).to eq("baseline_count" => 1, "anchor_count" => 41, "change" => 40)
      expect(block["layers"]["undeclared"]).to eq("baseline_count" => 2, "anchor_count" => 0, "change" => -2)
      # A layer that did not move is a measured zero, and a layer nobody declared is too.
      expect(block["layers"]["unit"]).to eq("baseline_count" => 2, "anchor_count" => 2, "change" => 0)
      expect(block["layers"]["system"]).to eq("baseline_count" => 0, "anchor_count" => 0, "change" => 0)
    end

    # @intent: { entity: "layer_run_growth", action: "reconcile with the recorded totals", behavior: "the per-layer changes sum to anchor_recorded_count minus baseline_recorded_count", layer: "request" }
    it "sums the per-layer changes to the difference of the recorded populations" do
      _window, block = blocks

      expect(block["baseline_recorded_count"]).to eq(5)
      expect(block["anchor_recorded_count"]).to eq(43)
      expect(block["layers"].values.sum { |layer| layer["change"] })
        .to eq(block["anchor_recorded_count"] - block["baseline_recorded_count"])
    end

    # @intent: { entity: "layer_run_growth", action: "sit beside directory_run_growth", behavior: "the pair is top-level and absent from latest_run, which keeps its single-run key set", layer: "request" }
    it "is top-level and not inside latest_run" do
      body = get_repository

      expect(body).to have_key("layer_run_growth")
      expect(body["latest_run"]).not_to have_key("layer_run_growth")
      expect(body["latest_run"]).not_to have_key("layer_run_growth_window")
    end

    # @intent: { entity: "layer_run_growth", action: "read the previous run's mix only when comparable", behavior: "a comparable pair reads the run-grain layer aggregate exactly twice and nothing it reads escapes the partition", layer: "request" }
    it "reads the run-grain layer mix exactly twice" do
      expect(run_layer_reads { get_repository }).to eq(2)
      reads = observation_reads { get_repository }
      expect(reads.length).to eq(classified_observation_reads { get_repository })
    end

    # @intent: { entity: "layer_run_growth", action: "re-anchor on commit_sha", behavior: "naming the earlier run anchors on it and baselines against its branch predecessor, as directory_run_growth_window does", layer: "request" }
    it "re-anchors with ?commit_sha= exactly as directory_run_growth_window" do
      ingest(mix("unit" => 9), commit_sha: "newest000001", at: 1.day.ago)

      body = get_repository(query: { commit_sha: "latest000001" })

      expect(body["layer_run_growth_window"]).to include("anchor_commit_sha" => "latest000001",
                                                         "baseline_commit_sha" => "previous0001",
                                                         "state" => "comparable")
      expect(body["layer_run_growth_window"].slice("anchor_commit_sha", "baseline_commit_sha"))
        .to eq(body["directory_run_growth_window"].slice("anchor_commit_sha", "baseline_commit_sha"))
      expect(body["layer_run_growth"]["layers"]["request"]["change"]).to eq(40)
    end
  end

  describe "the path is never consulted" do
    # NEGATIVE FIRST: an example declaring `unit` under spec/requests moves `unit`, not `request`.
    # @intent: { entity: "layer_run_growth", action: "ignore the directory", behavior: "an added example declaring unit under spec/requests moves unit and leaves request unchanged", layer: "request" }
    it "moves the declared layer, not the layer the directory suggests" do
      ingest([annotated_spec(file_path: "spec/requests/a_spec.rb", line_number: 1, layer: "unit")],
             commit_sha: "previous0001", at: 20.days.ago)
      ingest([annotated_spec(file_path: "spec/requests/a_spec.rb", line_number: 1, layer: "unit"),
              annotated_spec(file_path: "spec/requests/b_spec.rb", line_number: 2, layer: "unit")],
             commit_sha: "latest000001", at: 10.days.ago)

      _window, block = blocks

      expect(block["layers"]["unit"]["change"]).to eq(1)
      expect(block["layers"]["request"]["change"]).to eq(0)
    end
  end

  describe "every non-comparable state" do
    def expect_withheld(state, reads:)
      window, block = blocks

      expect(window).to include("state" => state, "comparable" => false)
      expect(block).to be_nil
      expect(run_layer_reads { get_repository }).to eq(reads)
    end

    # @intent: { entity: "layer_run_growth", action: "withhold on a first run", behavior: "the first run on a branch serves no_previous_run, a null block and a single run-layer read", layer: "request" }
    it "serves no_previous_run and reads the mix once on the first run on a branch" do
      ingest(mix("unit" => 2), commit_sha: "only00000001", at: 1.day.ago)

      expect_withheld("no_previous_run", reads: 1)
    end

    # @intent: { entity: "layer_run_growth", action: "withhold on a null branch", behavior: "a latest run that named no branch serves no_previous_run, a null block and a single run-layer read", layer: "request" }
    it "serves no_previous_run for a run that named no branch" do
      ingest(mix("unit" => 2), commit_sha: "prior00000001", at: 2.days.ago, branch: nil)
      ingest(mix("unit" => 2), commit_sha: "nobranch0001", at: 1.day.ago, branch: nil)

      expect_withheld("no_previous_run", reads: 1)
    end

    # @intent: { entity: "layer_run_growth", action: "withhold with no runs", behavior: "a repository CI has never reported on serves no_latest_run and a null block", layer: "request" }
    it "serves no_latest_run when CI has never reported" do
      window, block = blocks

      expect(window).to include("state" => "no_latest_run", "comparable" => false, "anchor_commit_sha" => nil)
      expect(block).to be_nil
    end

    # @intent: { entity: "layer_run_growth", action: "withhold before reading", behavior: "a previous run that reported no tests serves previous_unmeasured and never reads its mix", layer: "request" }
    it "decides previous_unmeasured before any read of the previous run" do
      ingest([], commit_sha: "previous0001", at: 20.days.ago, total: 0)
      ingest(mix("unit" => 2), commit_sha: "latest000001", at: 10.days.ago)

      expect_withheld("previous_unmeasured", reads: 1)
    end

    # @intent: { entity: "layer_run_growth", action: "withhold before reading", behavior: "a latest run that reported no tests serves latest_unmeasured and never reads the previous mix", layer: "request" }
    it "decides latest_unmeasured before any read of the previous run" do
      ingest(mix("unit" => 2), commit_sha: "previous0001", at: 20.days.ago)
      ingest([], commit_sha: "latest000001", at: 10.days.ago, total: 0)

      expect_withheld("latest_unmeasured", reads: 1)
    end

    # @intent: { entity: "layer_run_growth", action: "withhold on differently assembled runs", behavior: "runs assembled from different shard counts serve assembled_differently without reading the previous mix", layer: "request" }
    it "decides assembled_differently before any read of the previous run" do
      ingest(mix("unit" => 2), commit_sha: "previous0001", at: 20.days.ago)
      ingest(mix("unit" => 2), commit_sha: "latest000001", at: 10.days.ago)
      allow_any_instance_of(TestRun).to receive(:assembled_like?).and_return(false) # rubocop:disable RSpec/AnyInstance

      window, block = blocks

      expect(window).to include("state" => "assembled_differently", "comparable" => false)
      expect(block).to be_nil
      expect(run_layer_reads { get_repository }).to eq(1)
    end

    # @intent: { entity: "layer_run_growth", action: "withhold against a totals-only run", behavior: "a previous run that sent a suite size and no per-example rows serves previous_unrecorded and a null block rather than the whole suite as appearing", layer: "request" }
    it "serves previous_unrecorded when the previous run wrote no per-example rows" do
      ingest([], commit_sha: "previous0001", at: 20.days.ago, total: 10)
      ingest(mix("unit" => 2), commit_sha: "latest000001", at: 10.days.ago)

      expect_withheld("previous_unrecorded", reads: 2)
    end

    # @intent: { entity: "layer_run_growth", action: "withhold from a totals-only run", behavior: "a latest run that wrote no per-example rows serves latest_unrecorded and a null block", layer: "request" }
    it "serves latest_unrecorded when the latest run wrote no per-example rows" do
      ingest(mix("unit" => 2), commit_sha: "previous0001", at: 20.days.ago)
      ingest([], commit_sha: "latest000001", at: 10.days.ago, total: 10)

      expect_withheld("latest_unrecorded", reads: 2)
    end

    # @intent: { entity: "layer_run_growth", action: "withhold when neither run recorded", behavior: "two totals-only runs serve neither_recorded and a null block", layer: "request" }
    it "serves neither_recorded when neither run wrote per-example rows" do
      ingest([], commit_sha: "previous0001", at: 20.days.ago, total: 10)
      ingest([], commit_sha: "latest000001", at: 10.days.ago, total: 10)

      expect_withheld("neither_recorded", reads: 2)
    end
  end

  describe "the Overview panel line" do
    def declared_layers_line = Capybara.string(response.body).find("#changes #layer-run-growth")

    # @intent: { entity: "TestRun", action: "show the mix movement", behavior: "the Overview prints Since the previous sha7 on main with request +40 and undeclared −2 and the unmoved unit as ±0, from the same object the API serves", layer: "request" }
    it "prints the movement under the Declared layers row when comparable" do
      comparable_runs

      get repository_path(repository)

      expect(declared_layers_line).to have_text("Since previou on main:", normalize_ws: true)
      expect(declared_layers_line).to have_text("unit ±0 · request +40 · undeclared −2", normalize_ws: true)
    end

    # @intent: { entity: "TestRun", action: "omit the movement without a comparison", behavior: "a first run on a branch renders the Declared layers row and no movement line", layer: "request" }
    it "omits the line when there is no comparison" do
      ingest(mix("unit" => 2), commit_sha: "only00000001", at: 1.day.ago)

      get repository_path(repository)

      html = Capybara.string(response.body)
      expect(html.find("#layers").all("tbody tr").map { |row| row.all("td").first(2).map { |cell| cell.text.squish } })
        .to eq([%w[unit 2]])
      expect(html).to have_no_css("#layer-run-growth")
    end
  end
end
