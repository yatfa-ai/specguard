# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the "Examples in this spec file" drill-in (SPGD-1770): a file opened out of the
# layer-ranked "Heaviest spec files" row holds only that layer's examples, so its counts equal the
# row's and its captions stay true. The layer is what each example's `@intent` declared, never
# inferred from the path. The no-ask drill-in must be unchanged.
RSpec.describe "Repository spec-file examples — ?layer=", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  FILE = "spec/models/mixed_spec.rb"

  def page = Capybara.string(response.body)

  def drill = page.find("#spec-file-examples")

  def basis = drill.find("#spec-file-examples-basis").text.gsub(/\s+/, " ").strip

  def drill_rows = drill.all("tbody tr", visible: :all)

  def clear_link = page.first("#spec-file-examples-clear-layer", minimum: 0)

  def row_figures
    cells = page.find("#spec-file-durations").all("tbody tr").find { it.first("td").text.strip == FILE }.all("td")
    [cells[1].text.strip, cells[2].text.strip]
  end

  def observe(run, line:, duration:, layer:, path: FILE)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "example #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "filelayer001", branch: "main",
                               total_specs_count: 40, duration_seconds: 90.0)
    # 5 request examples at 3s (one untimed: partial coverage) and 20 unit examples at 5s.
    4.times { |i| observe(test_run, line: i + 1, duration: 3.0, layer: "request") }
    observe(test_run, line: 5, duration: nil, layer: "request")
    20.times { |i| observe(test_run, line: 100 + i, duration: 5.0, layer: "unit") }
    # The undeclared rows sit under a request-looking path: the path decides nothing.
    2.times { |i| observe(test_run, line: 200 + i, duration: 1.0, layer: nil, path: "spec/requests/plain_spec.rb") }
    test_run
  end

  # @intent: { entity: "GET /repositories/:id", action: "open a spec file within a layer", behavior: "?layer=request&spec_file= lists exactly the file's request examples, unasked lists all of them, and ?layer=unit lists the unit ones, with the layer note naming the layer", layer: "request" }
  it "narrows the drill-in to the layer's examples" do
    get repository_path(repository, spec_file: FILE)
    expect(drill_rows.size).to eq(25)
    expect(page).not_to have_css("#spec-file-examples-clear-layer")

    get repository_path(repository, spec_file: FILE, layer: "request")
    expect(drill_rows.size).to eq(5)
    expect(drill.all("tbody tr td:nth-child(2)", visible: :all).map { it.text.strip }.uniq).to eq(["request"])
    expect(basis).to include("declared request").and include("never inferred from the path")

    get repository_path(repository, spec_file: FILE, layer: "unit")
    expect(drill_rows.size).to eq(20)
  end

  # @intent: { entity: "GET /repositories/:id", action: "open a spec file within a layer", behavior: "under a layer the drill-in's recorded and timed counts equal the layer-ranked heaviest-files row's figures and the same-fraction sentence renders and is true", layer: "request" }
  it "states the same figures as the clicked row and the same-fraction sentence is true" do
    get repository_path(repository, layer: "request")
    figures = row_figures
    expect(figures.first).to eq("4 of 5")

    get repository_path(repository, layer: "request", spec_file: FILE)
    expect(basis).to include("All 5 request-layer examples this run recorded in it")
      .and include("Durations here cover 4 of 5")
      .and include("the same fraction the row for this file states in the panel above")
  end

  # @intent: { entity: "GET /repositories/:id", action: "offer a way back from the layer filter", behavior: "the file drill-in renders a Clear layer filter link that drops only the layer and keeps the file", layer: "request" }
  it "renders a clear link that drops only the layer" do
    get repository_path(repository, spec_file: FILE, layer: "request", commit_sha: "filelayer001")

    expect(clear_link.text.squish).to eq("Clear layer filter")
    expect(clear_link[:href]).not_to include("layer=")
    expect(clear_link[:href]).to include("spec_file=").and include("commit_sha=filelayer001")
  end

  # @intent: { entity: "GET /repositories/:id", action: "select the undeclared layer", behavior: "layer=undeclared lists only intent_layer NULL rows of the file, so a request-looking path decides nothing", layer: "request" }
  it "selects undeclared by the stored declaration, never the path" do
    get repository_path(repository, spec_file: "spec/requests/plain_spec.rb", layer: "undeclared")
    expect(drill_rows.size).to eq(2)

    get repository_path(repository, spec_file: "spec/requests/plain_spec.rb", layer: "request")
    expect(page).to have_css("#spec-file-examples-layer-empty")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state an empty layer in a recorded file", behavior: "a layer nothing in a recorded file declared renders a state naming the layer with a clear link, and never says the run recorded no examples in the file", layer: "system" }
  it "says the layer is empty, not that the file is unrecorded" do
    get repository_path(repository, spec_file: FILE, layer: "system")

    empty = page.find("#spec-file-examples-layer-empty")
    expect(empty.text.squish).to include("system").and include(FILE)
    expect(empty.text).not_to include("recorded no examples")
    expect(page).not_to have_text("This run recorded no examples in")
    expect(clear_link.text.squish).to eq("Clear layer filter")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state an unrecorded file under a layer", behavior: "a file the run never recorded keeps the no-examples state even when a layer is asked", layer: "request" }
  it "keeps the unrecorded-file state for a file the run never wrote" do
    get repository_path(repository, spec_file: "spec/nope_spec.rb", layer: "request")

    expect(drill.text).to include("This run recorded no examples in spec/nope_spec.rb")
    expect(page).not_to have_css("#spec-file-examples-layer-empty")
  end

  # @intent: { entity: "GET /repositories/:id", action: "ignore unknown layers", behavior: "an unknown, array or blank layer is no ask: the drill-in HTML is identical to the unasked one", layer: "request" }
  it "reads malformed layer asks as no ask" do
    panel_html = -> { page.find("#spec-file-examples").native.to_html }
    get repository_path(repository, spec_file: FILE)
    baseline = panel_html.call
    expect(baseline).not_to include("Clear layer filter")

    ["layer=bogus", "layer=", "layer[]=x"].each do |query|
      get "#{repository_path(repository, spec_file: FILE)}&#{query}"
      expect(response).to have_http_status(:ok), query
      expect(panel_html.call).to eq(baseline), query
    end
  end

  # @intent: { entity: "GET /repositories/:id", action: "count the layer ask's queries", behavior: "the asked non-empty drill-in issues the same single file statement as the unasked one, and the unasked path adds no existence read", layer: "request" }
  it "adds no statement against spec_observations for the file read" do
    file_reads = ->(sqls) { sqls.select { it.include?("file_recorded_count") } }
    unasked = queries_against("spec_observations") { get repository_path(repository, spec_file: FILE) }
    asked = queries_against("spec_observations") { get repository_path(repository, spec_file: FILE, layer: "request") }

    expect(file_reads.(unasked).size).to eq(1)
    expect(file_reads.(asked).size).to eq(1)
    expect(asked.size).to eq(unasked.size)
  end
end
