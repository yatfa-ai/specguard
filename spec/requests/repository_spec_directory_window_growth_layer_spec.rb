# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the "Areas that grew or shrank over the window" panel of repositories#show (SPGD-1782).
# The layer is what each example's `@intent` declared, never inferred from the path. The no-ask page must
# be unchanged.
RSpec.describe "Repository spec directory window growth — ?layer=", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def page = Capybara.string(response.body)

  def ingest(specs, commit_sha:, at:, total: nil)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: total || specs.size, annotated_specs_count: 0,
        duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at)
  end

  def examples(spec_list)
    spec_list.flat_map do |directory, layer, count|
      Array.new(count) do |index|
        annotated_spec(file_path: "#{directory}/#{layer}_#{index + 1}_spec.rb", line_number: index + 1,
                       layer: layer, name: "#{directory} #{layer} #{index + 1}")
      end
    end
  end

  def panel_text = page.find("#spec-directory-window-growth").text.gsub(/\s+/, " ").strip

  def panel_html = page.find("#spec-directory-window-growth").native.to_html

  def rows = page.find("#spec-directory-window-growth").all("tbody tr").map { it.all("td").first.text.strip }

  def window(baseline:, anchor:)
    ingest(examples(baseline), commit_sha: "baseline0001", at: 30.days.ago)
    ingest(examples(anchor), commit_sha: "anchor000001", at: 10.days.ago)
  end

  describe "a layer both ends have examples of" do
    before do
      window(baseline: [["spec/models", "request", 1], ["spec/models", "unit", 8], ["spec/services", "unit", 3]],
             anchor: [["spec/models", "request", 6], ["spec/models", "unit", 3], ["spec/jobs", "request", 2],
                      ["spec/services", "unit", 2]])
    end

    # @intent: { entity: "GET /repositories/:id", action: "narrow the window area panel to a layer", behavior: "?layer=request lists the areas that gained request examples across the window, says so once with a clear link, and names the rows as the layer's", layer: "request" }
    it "narrows the panel, states the layer once and names the rows as the layer's" do
      get repository_path(repository, branch: "main")
      expect(rows).to include("spec/services")
      expect(page).not_to have_css("#spec-directory-window-growth-clear-layer")
      expect(panel_text).not_to include("-layer example rows")

      get repository_path(repository, branch: "main", layer: "request", commit_sha: "anchor000001")
      expect(rows).to eq(%w[spec/models spec/jobs])
      expect(panel_text).to include("Only the request-layer examples").and include("at both ends of this window")
      expect(panel_text).not_to include("in both runs")
      expect(panel_text).to include("request-layer example rows")
      expect(page.all("#spec-directory-window-growth-clear-layer").size).to eq(1)

      link = page.find("#spec-directory-window-growth-clear-layer")
      expect(link.text.squish).to eq("Clear layer filter")
      expect(link[:href]).not_to include("layer=")
      expect(link[:href]).to include("branch=main").and end_with("#changes")
    end
  end

  describe "a layer that did not move in any area, while another layer did" do
    before do
      window(baseline: [["spec/models", "request", 3], ["spec/models", "unit", 1]],
             anchor: [["spec/models", "request", 3], ["spec/models", "unit", 5]])
    end

    # @intent: { entity: "GET /repositories/:id", action: "word the unmoved empty state for the layer", behavior: "an area whose request count is unchanged reads as no area moved, naming request-layer examples, though unit examples moved", layer: "request" }
    it "keeps the unmoved-areas empty state layer-aware" do
      get repository_path(repository, branch: "main")
      expect(rows).to eq(%w[spec/models])
      expect(panel_text).not_to include("No area moved across this window")

      get repository_path(repository, branch: "main", layer: "request")
      expect(panel_text).to include("No area moved across this window")
      expect(panel_text).to include("same number of request-layer examples in both")
    end
  end

  describe "a layer neither end has examples of" do
    before { window(baseline: [["spec/models", "unit", 4]], anchor: [["spec/models", "unit", 5]]) }

    # @intent: { entity: "GET /repositories/:id", action: "state a layer empty at both ends", behavior: "a layer neither end of the window has an example of renders a no-layer-examples state naming the layer, with a clear link", layer: "system" }
    it "says the layer is absent from both ends of the window" do
      get repository_path(repository, branch: "main", layer: "system")

      expect(panel_text).to include("No system-layer examples at either end of this window")
      expect(panel_text).not_to include("recorded no per-example")
      expect(panel_text).not_to include("No area moved across this window")
      expect(page).to have_css("#spec-directory-window-growth-clear-layer")
      expect(rows).to be_empty
    end
  end

  describe "a layer first appearing at the anchor" do
    before { window(baseline: [["spec/models", "unit", 4]], anchor: [["spec/models", "unit", 4], ["spec/jobs", "request", 2]]) }

    # @intent: { entity: "GET /repositories/:id", action: "state a layer new to the window", behavior: "a layer the baseline end had none of renders new areas, never the baseline-unrecorded refusal", layer: "request" }
    it "renders new areas, not a refusal" do
      get repository_path(repository, branch: "main", layer: "request")

      expect(rows).to eq(%w[spec/jobs])
      expect(panel_text).to include("New area")
      expect(panel_text).not_to include("recorded no per-example")
    end
  end

  describe "a baseline that recorded no per-example detail" do
    # @intent: { entity: "GET /repositories/:id", action: "keep the unrecorded refusal under a layer", behavior: "a baseline run with no per-example rows keeps its recorded-no-detail refusal when a layer is asked, with the layer stated", layer: "request" }
    it "keeps the refusal and still states the narrowing" do
      ingest([], commit_sha: "baseline0001", at: 30.days.ago, total: 5)
      ingest(examples([["spec/models", "request", 2]]), commit_sha: "anchor000001", at: 10.days.ago)

      get repository_path(repository, branch: "main", layer: "request")
      expect(panel_text).to include("recorded no per-example detail")
      expect(panel_text).to include("Only the request-layer examples")
    end
  end

  describe "a malformed layer ask" do
    # @intent: { entity: "GET /repositories/:id", action: "ignore unknown layers", behavior: "an unknown, blank or array layer is no ask: the window panel is identical to the unasked page", layer: "request" }
    it "reads as no ask" do
      window(baseline: [["spec/models", "request", 1], ["spec/models", "unit", 8]],
             anchor: [["spec/models", "request", 6], ["spec/models", "unit", 3]])
      get repository_path(repository, branch: "main")
      baseline = panel_html

      ["layer=bogus", "layer=", "layer[]=x"].each do |query|
        get "#{repository_path(repository, branch: "main")}&#{query}"
        expect(panel_html).to eq(baseline), query
      end
    end
  end

  describe "the filter-bar hint" do
    # @intent: { entity: "GET /repositories/:id", action: "say which sections the layer ask narrows", behavior: "the filter bar hint names the window area comparison of What changed beside the run-over-run ones", layer: "request" }
    it "names the window area comparison" do
      window(baseline: [["spec/models", "request", 1]], anchor: [["spec/models", "request", 2]])
      get repository_path(repository, branch: "main", layer: "request")

      hint = page.find("#rc-layer-scope").text.gsub(/\s+/, " ")
      expect(hint).to include("Areas that grew or shrank over the window")
      expect(hint).to include("every other section still counts all layers")
    end
  end
end
