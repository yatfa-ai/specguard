# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the "Spec files in this directory" drill-in (SPGD-1776): an area opened out of the
# layer-ranked "Heaviest spec directories" row holds only that layer's examples, so its counts equal the
# row's and its captions stay true. The layer is what each example's `@intent` declared, never inferred
# from the path. The no-ask drill-in must be unchanged.
RSpec.describe "Repository spec files in this directory — ?layer=", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }
  let(:area) { "spec/models" }

  def page = Capybara.string(response.body)

  def drill = page.find("#spec-directory-files")

  def basis = drill.find("#spec-directory-files-basis").text.gsub(/\s+/, " ").strip

  def drill_rows = drill.all("tbody tr", visible: :all)

  def clear_link = page.first("#spec-directory-files-clear-layer", minimum: 0)

  def observe(run, path:, line:, duration:, layer:)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "dirlayer0001", branch: "main",
                               total_specs_count: 40, duration_seconds: 90.0)
    observe(test_run, path: "spec/models/a_spec.rb", line: 1, duration: 3.0, layer: "request")
    observe(test_run, path: "spec/models/a_spec.rb", line: 2, duration: nil, layer: "request")
    2.times { |i| observe(test_run, path: "spec/models/a_spec.rb", line: 10 + i, duration: 20.0, layer: "unit") }
    observe(test_run, path: "spec/models/b_spec.rb", line: 1, duration: 4.0, layer: "request")
    observe(test_run, path: "spec/models/c_spec.rb", line: 1, duration: 30.0, layer: "unit")
    # Undeclared rows under a request-looking path: the path decides nothing.
    2.times { |i| observe(test_run, path: "spec/requests/plain_spec.rb", line: i + 1, duration: 1.0, layer: nil) }
    test_run
  end

  # @intent: { entity: "GET /repositories/:id", action: "open a spec directory within a layer", behavior: "?layer=request&spec_directory= lists exactly the area's files holding a request example, unasked lists them all, and the basis note names the layer", layer: "request" }
  it "narrows the drill-in to the layer's files" do
    get repository_path(repository, spec_directory: area)
    expect(drill_rows.size).to eq(3)
    expect(page).not_to have_css("#spec-directory-files-clear-layer")

    get repository_path(repository, spec_directory: area, layer: "request")
    expect(drill_rows.map { it.first("td").text.strip }).to eq(%w[spec/models/b_spec.rb spec/models/a_spec.rb])
    expect(basis).to include("request-layer examples").and include("never inferred from the path")
  end

  # @intent: { entity: "GET /repositories/:id", action: "open a spec directory within a layer", behavior: "the opened area is a row of the layer-ranked rollup, states that row's fraction, and the same-fraction sentence renders and is true", layer: "request" }
  it "states the same fraction as the clicked rollup row" do
    get repository_path(repository, layer: "request")
    row = page.find("#spec-directory-durations").all("tbody tr").find { it.first("td").text.strip == area }
    expect(row.all("td")[1].text.strip).to eq("2 of 3")

    get repository_path(repository, spec_directory: area, layer: "request")
    expect(basis).to include("durations cover 2 of 3")
      .and include("the same fraction the row for this area states in the panel above")
  end

  # @intent: { entity: "GET /repositories/:id", action: "offer a way back from the layer filter", behavior: "the area drill-in renders a Clear layer filter link that drops only the layer and keeps the spec_directory", layer: "request" }
  it "renders a clear link that drops only the layer and keeps the area" do
    get repository_path(repository, spec_directory: area, layer: "request", commit_sha: "dirlayer0001")

    expect(clear_link.text.squish).to eq("Clear layer filter")
    expect(clear_link[:href]).not_to include("layer=")
    expect(clear_link[:href]).to include("spec_directory=").and include("commit_sha=dirlayer0001")
      .and end_with("#spec-directory-files")
  end

  # @intent: { entity: "GET /repositories/:id", action: "select the undeclared layer", behavior: "layer=undeclared lists only intent_layer NULL files of the area, so a request-looking path decides nothing", layer: "request" }
  it "selects undeclared by the stored declaration, never the path" do
    get repository_path(repository, spec_directory: "spec/requests", layer: "undeclared")
    expect(drill_rows.size).to eq(1)

    get repository_path(repository, spec_directory: "spec/requests", layer: "request")
    expect(page).to have_css("#spec-directory-files-layer-empty")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state an empty layer in a recorded area", behavior: "a layer nothing in a recorded area declared renders a state naming the layer with a clear link, and never says the run recorded no examples in the area", layer: "system" }
  it "says the layer is empty, not that the area is unrecorded" do
    get repository_path(repository, spec_directory: area, layer: "system")

    empty = page.find("#spec-directory-files-layer-empty")
    expect(empty.text.squish).to include("system").and include(area)
    expect(empty.text).not_to include("recorded no examples")
    expect(page).not_to have_text("This run recorded no examples in")
    expect(clear_link.text.squish).to eq("Clear layer filter")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state an unrecorded area under a layer", behavior: "an area the run never recorded keeps the no-spec-files state even when a layer is asked", layer: "request" }
  it "keeps the unrecorded-area state for an area the run never wrote" do
    get repository_path(repository, spec_directory: "spec/nope", layer: "request")

    expect(drill.text).to include("This run recorded no examples in spec/nope")
    expect(page).not_to have_css("#spec-directory-files-layer-empty")
  end

  # @intent: { entity: "GET /repositories/:id", action: "ignore unknown layers", behavior: "an unknown, array or blank layer is no ask: the area drill-in HTML is identical to the unasked one", layer: "request" }
  it "reads malformed layer asks as no ask" do
    panel_html = -> { page.find("#spec-directory-files").native.to_html }
    get repository_path(repository, spec_directory: area)
    baseline = panel_html.call
    expect(baseline).not_to include("Clear layer filter")

    ["layer=bogus", "layer=", "layer[]=x"].each do |query|
      get "#{repository_path(repository, spec_directory: area)}&#{query}"
      expect(response).to have_http_status(:ok), query
      expect(panel_html.call).to eq(baseline), query
    end
  end

  # @intent: { entity: "GET /repositories/:id", action: "count the layer ask's queries", behavior: "the asked non-empty area drill-in issues the same statements against spec_observations as the unasked one, and only the empty-layer ask adds one existence read", layer: "request" }
  it "adds no statement for the asked non-empty read and exactly one for the empty one" do
    unasked = queries_against("spec_observations") { get repository_path(repository, spec_directory: area) }
    asked = queries_against("spec_observations") { get repository_path(repository, spec_directory: area, layer: "request") }
    empty = queries_against("spec_observations") { get repository_path(repository, spec_directory: area, layer: "system") }

    expect(asked.size).to eq(unasked.size)
    expect(empty.size).to eq(unasked.size + 1)
  end
end
