# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the branch-WINDOW area block of `GET /api/v1/repository` (SPGD-1782): `directory_growth`
# and its contract block `directory_growth_window`, served with `?branch=`. The layer is what each
# example's own `@intent` declared, never inferred from the path. Rows are written by
# `Ingest::RunRecorder`, so every state is one a real client produces.
RSpec.describe "GET /api/v1/repository — ?layer= on directory_growth", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def get_repository(query: {})
    token = repository.api_keys.create!.raw_token
    get "/api/v1/repository", params: query, headers: { "Authorization" => "Bearer #{token}" }

    response.parsed_body
  end

  def ingest(specs, commit_sha:, at:, total: nil, branch: "main")
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: branch, total_specs_count: total || specs.size,
        annotated_specs_count: 0, duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at)
    run
  end

  # `[["spec/models", "request", 5], ...]` — that many examples of that layer in that area, each in its
  # own file named for the layer. A nil layer is undeclared.
  def examples(spec_list)
    spec_list.flat_map do |directory, layer, count|
      Array.new(count) do |index|
        file = "#{directory}/#{layer || "plain"}_#{index + 1}_spec.rb"
        if layer
          annotated_spec(file_path: file, line_number: index + 1, layer: layer, name: "#{directory} #{layer} #{index + 1}")
        else
          unannotated_spec(file_path: file, line_number: index + 1, name: "#{directory} plain #{index + 1}")
        end
      end
    end
  end

  # The window's two ENDS differ; the middle run is a decoy that swings past both.
  def window(baseline:, anchor:, middle: baseline)
    ingest(examples(baseline), commit_sha: "baseline0001", at: 30.days.ago)
    ingest(examples(middle), commit_sha: "middle000001", at: 20.days.ago)
    ingest(examples(anchor), commit_sha: "anchor000001", at: 10.days.ago)
  end

  def blocks(query: {})
    body = get_repository(query: { branch: "main" }.merge(query))
    [body["directory_growth_window"], body["directory_growth"], body]
  end

  def row_at(block, path) = block["rows"].find { |row| row["path"] == path }

  describe "a layer both ends of the window have examples of" do
    before do
      # spec/models: +5 request, -5 unit (±0 unasked). spec/jobs: +2 request. spec/services: unit only, -1.
      window(
        baseline: [["spec/models", "request", 1], ["spec/models", "unit", 8], ["spec/services", "unit", 3]],
        middle: [["spec/models", "request", 20], ["spec/jobs", "request", 9]],
        anchor: [["spec/models", "request", 6], ["spec/models", "unit", 3], ["spec/jobs", "request", 2],
                 ["spec/services", "unit", 2]]
      )
    end

    # @intent: { entity: "directory_growth", action: "narrow the window area rollup to a layer", behavior: "?branch=main&layer=request counts only declared request examples at the two endpoint runs, ranked by the layer's movement, where unasked the same area nets to zero", layer: "request" }
    it "counts the layer's examples at the two endpoints and ranks by the layer's movement" do
      _window, unasked, = blocks
      expect(row_at(unasked, "spec/models")).to include("baseline_count" => 9, "anchor_count" => 9, "change" => 0)
      expect(unasked).not_to have_key("layer")

      window, asked, = blocks(query: { layer: "request" })
      expect(window).to include("layer" => "request", "grouped" => true)
      expect(asked["layer"]).to eq("request")
      expect(asked).to include("state" => "comparable", "comparable" => true)
      # spec/services holds only unit examples: it is not an area of the request layer at all.
      expect(asked["rows"].map { |row| row["path"] }).to eq(%w[spec/models spec/jobs])
      expect(row_at(asked, "spec/models")).to include("baseline_count" => 1, "anchor_count" => 6, "change" => 5)
      expect(row_at(asked, "spec/jobs")).to include("baseline_count" => 0, "anchor_count" => 2, "new_area" => true)
      expect(asked).to include("directory_count" => 2, "baseline_recorded_count" => 1, "anchor_recorded_count" => 8,
                               "truncated" => false)
    end

    # @intent: { entity: "directory_growth", action: "reconcile the window area rollup with the layer mix", behavior: "uncapped, the sum of directory_growth change under ?layer=L equals layer_growth layers[L] change for the same request", layer: "request" }
    it "sums to the layer_growth change for the same layer" do
      %w[request unit].each do |layer|
        _window, block, body = blocks(query: { layer: layer })
        expect(block["truncated"]).to be(false)
        expect(block["rows"].sum { |row| row["change"] }).to eq(body["layer_growth"]["layers"][layer]["change"]), layer
      end
    end

    # @intent: { entity: "directory_growth", action: "ignore unknown layers", behavior: "an unknown, blank or array layer is no ask: directory_growth and its window are byte-identical to the unasked response with no layer key", layer: "request" }
    it "reads malformed layer asks as no ask" do
      baseline = blocks.first(2)

      [{ layer: "bogus" }, { layer: "" }, { layer: ["request"] }].each do |extra|
        asked = blocks(query: extra).first(2)
        expect(asked).to eq(baseline), extra.inspect
        expect(asked.first).not_to have_key("layer")
      end
    end

    # @intent: { entity: "directory_growth", action: "leave an unbranched ask alone", behavior: "a layer without ?branch= serves directory_growth null and no layer echo, because nothing was narrowed", layer: "request" }
    it "serves null and echoes nothing for a layer asked without a branch" do
      body = get_repository(query: { layer: "request" })

      expect(body["directory_growth"]).to be_nil
      expect(body["directory_growth_window"]).to include("grouped" => false)
      expect(body["directory_growth_window"]).not_to have_key("layer")
    end

    # @intent: { entity: "directory_growth", action: "count the layer ask's queries", behavior: "asking for a layer on a branch adds no spec_observations statement over the unasked response, and the unasked read carries no layer predicate", layer: "request" }
    it "issues the same number of spec_observations statements asked as unasked" do
      unasked = queries_against("spec_observations") { blocks }
      asked = queries_against("spec_observations") { blocks(query: { layer: "request" }) }

      expect(asked.size).to eq(unasked.size)
      expect(unasked.grep(/intent_layer/).size).to be < asked.grep(/intent_layer/).size
    end
  end

  describe "a layer the BASELINE end had no examples of" do
    before do
      window(baseline: [["spec/models", "unit", 4]],
             anchor: [["spec/models", "unit", 4], ["spec/models", "request", 3], ["spec/jobs", "request", 2]])
    end

    # @intent: { entity: "directory_growth", action: "compare a newly introduced layer", behavior: "a layer first appearing at the anchor is comparable with new_area rows, never baseline_unrecorded", layer: "request" }
    it "is comparable with new areas" do
      window, block, = blocks(query: { layer: "request" })

      expect(block).to include("state" => "comparable", "comparable" => true, "layer" => "request",
                               "baseline_recorded_count" => 0, "anchor_recorded_count" => 5, "directory_count" => 2)
      expect(block["rows"].map { |row| [row["path"], row["new_area"], row["change"]] })
        .to eq([["spec/models", true, 3], ["spec/jobs", true, 2]])
      expect(window).to include("layer" => "request")
    end
  end

  describe "a layer the ANCHOR end no longer has" do
    before do
      window(baseline: [["spec/models", "unit", 4], ["spec/models", "request", 3]], anchor: [["spec/models", "unit", 4]])
    end

    # @intent: { entity: "directory_growth", action: "compare a removed layer", behavior: "a layer empty only at the anchor is comparable with removed_area rows", layer: "request" }
    it "reads the area as removed" do
      _window, block, = blocks(query: { layer: "request" })

      expect(block).to include("state" => "comparable", "baseline_recorded_count" => 3, "anchor_recorded_count" => 0)
      expect(row_at(block, "spec/models")).to include("removed_area" => true, "change" => -3)
    end
  end

  describe "a layer neither end has examples of" do
    before { window(baseline: [["spec/models", "unit", 4]], anchor: [["spec/models", "unit", 5]]) }

    # @intent: { entity: "directory_growth", action: "answer a layer empty at both ends", behavior: "comparable with zero rows and directory_count 0, not neither_recorded", layer: "system" }
    it "is the defined comparable-but-empty answer" do
      window, block, = blocks(query: { layer: "system" })

      expect(window).to include("layer" => "system")
      expect(block).to include("state" => "comparable", "comparable" => true, "rows" => [], "directory_count" => 0,
                               "truncated" => false, "layer" => "system",
                               "baseline_recorded_count" => 0, "anchor_recorded_count" => 0)
    end
  end

  describe "an end that recorded no per-example detail" do
    # @intent: { entity: "directory_growth", action: "keep the unrecorded refusal under a layer", behavior: "a baseline with no per-example rows still reads baseline_unrecorded when a layer is asked, with the layer echoed", layer: "request" }
    it "keeps baseline_unrecorded at run grain" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 5)
      ingest(examples([["spec/models", "request", 2]]), commit_sha: "anchor000001", at: 10.days.ago)

      window, block, = blocks(query: { layer: "request" })
      expect(block).to include("state" => "baseline_unrecorded", "comparable" => false, "rows" => [], "layer" => "request")
      expect(window).to include("layer" => "request")
    end

    # @intent: { entity: "directory_growth", action: "keep the unrecorded refusal under a layer", behavior: "an anchor with no per-example rows still reads anchor_unrecorded when a layer is asked", layer: "request" }
    it "keeps anchor_unrecorded at run grain" do
      ingest(examples([["spec/models", "request", 2]]), commit_sha: "baseline0001", at: 30.days.ago)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 2)

      _window, block, = blocks(query: { layer: "request" })
      expect(block).to include("state" => "anchor_unrecorded", "layer" => "request")
    end

    # @intent: { entity: "directory_growth", action: "keep the unrecorded refusal under a layer", behavior: "neither end with per-example rows still reads neither_recorded when a layer is asked", layer: "request" }
    it "keeps neither_recorded at run grain" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 2)
      ingest([], commit_sha: "anchor000001", at: 10.days.ago, total: 3)

      _window, block, = blocks(query: { layer: "request" })
      expect(block).to include("state" => "neither_recorded")
    end
  end

  describe "a window the walk refuses" do
    # @intent: { entity: "directory_growth", action: "echo the layer on a walk-decided refusal", behavior: "a one-run window reads no_earlier_run with the layer echoed on the contract block and issues no spec_observations read for the area comparison", layer: "request" }
    it "carries the layer into the state and issues no area read" do
      ingest(examples([["spec/models", "request", 2]]), commit_sha: "only00000001", at: 10.days.ago)

      window, block, = blocks(query: { layer: "request" })
      expect(block).to include("state" => "no_earlier_run", "layer" => "request", "rows" => [])
      expect(window).to include("layer" => "request")
      expect(block["directory_count"]).to be_nil
      expect(queries_against("spec_observations") { blocks(query: { layer: "request" }) }
               .grep(/ABS\(COUNT\(\*\) FILTER/)).to be_empty
    end
  end
end
