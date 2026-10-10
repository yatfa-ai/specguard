# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the "Heaviest spec files" panel (SPGD-1758): the rollup is ranked by ONE declared
# layer's time, in the query before the LIMIT. The layer is what each example's `@intent` declared,
# never inferred from the path. The no-ask page must be unchanged.
RSpec.describe "Repository heaviest spec files — ?layer=", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def page = Capybara.string(response.body)

  def panel = page.find("#spec-file-durations")

  def basis = panel.find("#spec-file-durations-basis").text.gsub(/\s+/, " ").strip

  def clear_link = page.first("#spec-file-durations-clear-layer a", minimum: 0)

  def row_paths = panel.all("tbody tr").map { it.all("td").first.text.strip }

  def observe(run, path:, line:, duration:, layer:)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "panelfile001", branch: "main",
                               total_specs_count: 30, duration_seconds: 90.0)
    # Eleven heavy unit files: the unasked default top ten cannot reach the request-heavy file.
    11.times { |i| observe(test_run, path: format("spec/unit/u%02d_spec.rb", i), line: 1, duration: 5.0, layer: "unit") }
    5.times { |i| observe(test_run, path: "spec/models/slow_requests_spec.rb", line: i + 1, duration: 0.9, layer: "request") }
    observe(test_run, path: "spec/requests/login_spec.rb", line: 1, duration: 3.0, layer: nil)
    test_run
  end

  # @intent: { entity: "GET /repositories/:id", action: "rank the heaviest files by a layer", behavior: "?layer=request lists the request-layer files with the layer's own counts and the caption names the layer, where the unasked panel does not show that file at all", layer: "request" }
  it "ranks by the layer and says so in the caption" do
    get repository_path(repository)
    expect(row_paths).not_to include("spec/models/slow_requests_spec.rb")
    expect(basis).not_to include("Ranked by the time of the examples that declared")

    get repository_path(repository, layer: "request")

    expect(row_paths).to eq(["spec/models/slow_requests_spec.rb"])
    expect(panel.all("tbody tr").first.all("td")[1].text.strip).to eq("5 of 5")
    expect(basis).to include("Ranked by the time of the examples that declared request")
      .and include("never inferred from the path")
  end

  # @intent: { entity: "GET /repositories/:id", action: "offer a way back from the layer filter", behavior: "an active layer renders a Clear layer filter link on the populated spec files panel that drops only the layer", layer: "request" }
  it "renders a clear link that drops only the layer" do
    get repository_path(repository, layer: "request", commit_sha: "panelfile001", branch: "main")

    expect(clear_link.text).to eq("Clear layer filter")
    expect(clear_link[:href]).not_to include("layer=")
    expect(clear_link[:href]).to include("commit_sha=panelfile001").and include("branch=main")
      .and end_with("#spec-file-durations")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state an empty layer", behavior: "a layer no example declared renders the spec files panel with an empty-layer sentence and a clear link, not no panel", layer: "request" }
  it "renders the panel with an empty answer for a layer nothing declared" do
    get repository_path(repository, layer: "system")

    expect(page).to have_css("#spec-file-durations")
    expect(panel.all("tbody tr")).to be_empty
    expect(basis).to include("No example of this run declared system")
    expect(clear_link.text).to eq("Clear layer filter")
  end

  # @intent: { entity: "GET /repositories/:id", action: "select the undeclared layer", behavior: "?layer=undeclared lists the file whose examples declared nothing even though it lives under spec/requests", layer: "request" }
  it "decides the layer by the declaration, never the path" do
    get repository_path(repository, layer: "undeclared")

    expect(row_paths).to eq(["spec/requests/login_spec.rb"])
  end

  # @intent: { entity: "GET /repositories/:id", action: "carry the layer through the file drill-down", behavior: "with a layer active the file links keep the layer so the drill-in rides the existing ask", layer: "request" }
  it "carries the layer through the row links" do
    get repository_path(repository, layer: "request")

    expect(panel.first("tbody tr a[href*='spec_file=']")[:href]).to include("layer=request")
  end

  # @intent: { entity: "GET /repositories/:id", action: "route from a layer to its files", behavior: "Spec files by declared layer links each layer to the spec file ranking by that layer on the spec-file-durations anchor, keeping other asks, while the Time by declared layer slowest-examples links are unchanged", layer: "request" }
  it "offers a files route per layer beside the slowest-examples links" do
    get repository_path(repository, branch: "main", commit_sha: "panelfile001", layer: "request")

    names = page.all("#layer-durations a")
    files = page.all("#layer-durations-files a")

    expect(names.map(&:text)).to eq(%w[unit request undeclared])
    expect(names.map { it[:href] }).to all(end_with("#slowest-examples"))
    expect(files.map(&:text)).to eq(names.map(&:text))
    files.each do |link|
      expect(link[:href]).to include("layer=#{link.text}").and end_with("#spec-file-durations")
      expect(link[:href]).to include("branch=main").and include("commit_sha=panelfile001")
    end
    # `aria-current` marks the active layer on both lines.
    expect(files.select { it[:"aria-current"] == "true" }.map(&:text)).to eq(["request"])
    expect(names.select { it[:"aria-current"] == "true" }.map(&:text)).to eq(["request"])
  end
end
