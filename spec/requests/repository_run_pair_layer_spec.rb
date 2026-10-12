# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the three run-over-run area panels of repositories#show (SPGD-1780): "Areas that grew or
# shrank", "Areas that got slower or faster" and "Files that grew or shrank in this directory". The layer is
# what each example's `@intent` declared, never inferred from the path. The no-ask page must be unchanged.
RSpec.describe "Repository run-over-run area panels — ?layer=", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def page = Capybara.string(response.body)

  def ingest(specs, commit_sha:, at:)
    run = Ingest::RunRecorder.record(
      repository,
      { commit_sha: commit_sha, branch: "main", total_specs_count: specs.size, annotated_specs_count: 0,
        duration_seconds: 60.0 },
      specs: specs.map(&:deep_stringify_keys)
    )
    TestRun.where(id: run.id).update_all(created_at: at)
  end

  def examples(spec_list)
    spec_list.flat_map do |directory, layer, count, seconds|
      Array.new(count) do |index|
        annotated_spec(file_path: "#{directory}/#{layer}_#{index + 1}_spec.rb", line_number: index + 1,
                       layer: layer, duration: seconds, name: "#{directory} #{layer} #{index + 1}")
      end
    end
  end

  def panel_text(id) = page.find(id).text.gsub(/\s+/, " ").strip

  def rows_of(id) = page.find(id).all("tbody tr").map { it.all("td").first.text.strip }

  def panel_html(id) = page.find(id).native.to_html

  before do
    ingest(examples([["spec/models", "request", 1, 2.0], ["spec/models", "unit", 8, 0.5],
                     ["spec/services", "unit", 3, 1.0]]), commit_sha: "previous0001", at: 20.days.ago)
    ingest(examples([["spec/models", "request", 6, 3.0], ["spec/models", "unit", 3, 0.5],
                     ["spec/jobs", "request", 2, 1.0], ["spec/services", "unit", 2, 1.0]]),
           commit_sha: "latest000001", at: 10.days.ago)
  end

  # @intent: { entity: "GET /repositories/:id", action: "narrow the area panels to a layer", behavior: "?layer=request lists the areas that gained request examples with the layer's counts where unasked the same area nets to zero, and each panel states the narrowing once with a clear link", layer: "request" }
  it "narrows the count and runtime panels and states the layer with a clear link" do
    get repository_path(repository)
    expect(rows_of("#spec-directory-growth")).to include("spec/services")
    expect(page).not_to have_css("#spec-directory-growth-clear-layer")
    expect(page).not_to have_css("#spec-directory-runtime-growth-clear-layer")

    get repository_path(repository, layer: "request", commit_sha: "latest000001")
    expect(rows_of("#spec-directory-growth")).to eq(%w[spec/models spec/jobs])
    expect(panel_text("#spec-directory-growth")).to include("Only the request-layer examples")
    expect(rows_of("#spec-directory-runtime-growth")).to contain_exactly("spec/models", "spec/jobs")
    expect(panel_text("#spec-directory-runtime-growth")).to include("Only the request-layer examples")

    %w[spec-directory-growth spec-directory-runtime-growth].each do |id|
      link = page.find("##{id}-clear-layer")
      expect(link.text.squish).to eq("Clear layer filter")
      expect(link[:href]).not_to include("layer=")
      expect(link[:href]).to include("commit_sha=latest000001").and end_with("#changes")
    end
  end

  # @intent: { entity: "GET /repositories/:id", action: "narrow the file drill-in with the rollup", behavior: "?spec_directory=&layer=request narrows the files that grew or shrank panel to the layer with a clear link that keeps the area", layer: "request" }
  it "narrows the files drill-in together with the rollup" do
    get repository_path(repository, spec_directory: "spec/models", layer: "request")

    expect(rows_of("#spec-directory-file-growth")).to include("spec/models/request_2_spec.rb")
    expect(rows_of("#spec-directory-file-growth").grep(/unit/)).to be_empty
    expect(panel_text("#spec-directory-file-growth")).to include("Only the request-layer examples")
    link = page.find("#spec-directory-file-growth-clear-layer")
    expect(link[:href]).not_to include("layer=")
    expect(link[:href]).to include("spec_directory=")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state a layer new to the latest run", behavior: "a layer the previous run had no examples of renders new areas on both panels, never the unrecorded or untimed refusals", layer: "system" }
  it "renders new areas, not a refusal, for a layer the previous run had none of" do
    ingest(examples([["spec/models", "request", 6, 3.0], ["spec/jobs", "system", 2, 1.0]]),
           commit_sha: "latest000002", at: 5.days.ago)

    get repository_path(repository, layer: "system")
    expect(rows_of("#spec-directory-growth")).to eq(%w[spec/jobs])
    expect(page.find("#spec-directory-growth").text).to include("New area")
    expect(rows_of("#spec-directory-runtime-growth")).to eq(%w[spec/jobs])
    expect(page.find("#spec-directory-runtime-growth").text).not_to include("recorded no per-example")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state a layer empty in both runs", behavior: "a layer neither run has an example of renders a no-layer-examples state naming the layer with a clear link on both panels", layer: "system" }
  it "says the layer is absent from both runs" do
    get repository_path(repository, layer: "system")

    %w[#spec-directory-growth #spec-directory-runtime-growth].each do |id|
      expect(panel_text(id)).to include("No system-layer examples in either run")
      expect(panel_text(id)).not_to include("recorded no per-example")
      expect(page).to have_css("#{id}-clear-layer")
    end
  end

  # @intent: { entity: "GET /repositories/:id", action: "ignore unknown layers", behavior: "an unknown, blank or array layer is no ask: the three panels are identical to the unasked page", layer: "request" }
  it "reads malformed layer asks as no ask" do
    ids = %w[#spec-directory-growth #spec-directory-runtime-growth #spec-directory-file-growth]
    base = repository_path(repository, spec_directory: "spec/models")
    get base
    baseline = ids.map { panel_html(it) }

    ["layer=bogus", "layer=", "layer[]=x"].each do |query|
      get "#{base}&#{query}"
      expect(ids.map { panel_html(it) }).to eq(baseline), query
    end
  end

  # @intent: { entity: "GET /repositories/:id", action: "say which sections the layer ask narrows", behavior: "the filter bar hint names the area comparisons of What changed and no longer says every other section counts all layers without them", layer: "request" }
  it "names the area comparisons in the filter-bar hint" do
    get repository_path(repository, layer: "request")

    hint = page.find("#rc-layer-scope").text.gsub(/\s+/, " ")
    expect(hint).to include("What changed").and include("Areas that grew or shrank")
      .and include("Areas that got slower or faster")
    expect(hint).to include("every other section still counts all layers")
  end
end
