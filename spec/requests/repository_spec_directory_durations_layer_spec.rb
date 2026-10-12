# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the "Heaviest spec directories" panel (SPGD-1761): the rollup is ranked by ONE declared
# layer's time, in the query before the LIMIT. The layer is what each example's `@intent` declared,
# never inferred from the path. The no-ask page must be unchanged.
RSpec.describe "Repository heaviest spec directories — ?layer=", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def page = Capybara.string(response.body)

  def panel = page.find("#spec-directory-durations")

  def basis = panel.find("#spec-directory-durations-basis").text.gsub(/\s+/, " ").strip

  def clear_link = page.first("#spec-directory-durations-clear-layer a", minimum: 0)

  def row_paths = panel.all("tbody tr").map { it.all("td").first.text.strip }

  def observe(run, path:, line:, duration:, layer:)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "#{path} #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "paneldir0001", branch: "main",
                               total_specs_count: 30, duration_seconds: 90.0)
    # Eleven heavy unit areas: the unasked default top ten cannot reach the request-heavy area.
    11.times { |i| observe(test_run, path: format("spec/unit%02d/a_spec.rb", i), line: 1, duration: 5.0, layer: "unit") }
    5.times { |i| observe(test_run, path: "spec/slow_requests/a_spec.rb", line: i + 1, duration: 0.9, layer: "request") }
    observe(test_run, path: "spec/requests/login_spec.rb", line: 1, duration: 3.0, layer: nil)
    test_run
  end

  # @intent: { entity: "GET /repositories/:id", action: "rank the heaviest directories by a layer", behavior: "?layer=request lists the request-layer areas with the layer's own counts and the caption names the layer, where the unasked panel does not show that area at all", layer: "request" }
  it "ranks by the layer and says so in the caption" do
    get repository_path(repository)
    expect(row_paths).not_to include("spec/slow_requests")
    expect(basis).not_to include("Ranked by the time of the examples that declared")

    get repository_path(repository, layer: "request")

    expect(row_paths).to eq(["spec/slow_requests"])
    expect(panel.all("tbody tr").first.all("td")[1].text.strip).to eq("5 of 5")
    expect(basis).to include("Ranked by the time of the examples that declared request")
      .and include("never inferred from the path")
    expect(basis).to include("All 1 directory")
  end

  # @intent: { entity: "GET /repositories/:id", action: "offer a way back from the layer filter", behavior: "an active layer renders a Clear layer filter link on the populated spec directories panel that drops only the layer", layer: "request" }
  it "renders a clear link that drops only the layer" do
    get repository_path(repository, layer: "request", commit_sha: "paneldir0001", branch: "main")

    expect(clear_link.text).to eq("Clear layer filter")
    expect(clear_link[:href]).not_to include("layer=")
    expect(clear_link[:href]).to include("commit_sha=paneldir0001").and include("branch=main")
      .and end_with("#spec-directory-durations")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state an empty layer", behavior: "a layer no example declared renders the spec directories panel with an empty-layer sentence and a clear link, not no panel", layer: "request" }
  it "renders the panel with an empty answer for a layer nothing declared" do
    get repository_path(repository, layer: "system")

    expect(page).to have_css("#spec-directory-durations")
    expect(panel.all("tbody tr")).to be_empty
    expect(basis).to include("No example of this run declared system")
    expect(clear_link.text).to eq("Clear layer filter")
  end

  # @intent: { entity: "GET /repositories/:id", action: "select the undeclared layer", behavior: "?layer=undeclared lists the area whose examples declared nothing even though it lives under spec/requests", layer: "request" }
  it "decides the layer by the declaration, never the path" do
    get repository_path(repository, layer: "undeclared")

    expect(row_paths).to eq(["spec/requests"])
  end

  # @intent: { entity: "GET /repositories/:id", action: "carry the layer through the area drill-down", behavior: "with a layer active the area links keep the layer so the drill-in rides the existing ask", layer: "request" }
  it "carries the layer through the row links" do
    get repository_path(repository, layer: "request")

    expect(panel.first("tbody tr a[href*='spec_directory=']")[:href]).to include("layer=request")
  end

  # The cross-reference sentence at the open-area panel claims the rollup row "states the same
  # fraction". Under a layer (SPGD-1776) the open area is narrowed to that layer too, so the claim is
  # true wherever the area is a row of the rollup, and still withheld where it is not.
  # @intent: { entity: "GET /repositories/:id", action: "cross-reference the layer-narrowed rollup row", behavior: "with a layer asked the open area states the layer's fraction and the same-fraction sentence renders only when the area is a row of the layer-ranked rollup", layer: "request" }
  it "renders the same-fraction cross-reference under a layer only for an area that is a rollup row" do
    sentence = "the same fraction the row for this area states in the panel above"
    # A sixth request example, untimed, so the "durations cover" branch (the one carrying the claim) renders.
    observe(run, path: "spec/slow_requests/b_spec.rb", line: 1, duration: nil, layer: "request")
    # A unit example in the same area: the request-layer fraction must ignore it.
    observe(run, path: "spec/slow_requests/b_spec.rb", line: 2, duration: nil, layer: "unit")

    get repository_path(repository, spec_directory: "spec/slow_requests", layer: "request")
    text = page.find("#spec-directory-files").text.gsub(/\s+/, " ")
    expect(text).to include("durations cover 5 of 6").and include(sentence)
    row = panel.all("tbody tr").find { it.first("td").text.strip == "spec/slow_requests" }
    expect(row.all("td")[1].text.strip).to eq("5 of 6")

    # An area that is not a row of the layer-ranked rollup keeps the cross-reference withheld.
    observe(run, path: "spec/unit10/b_spec.rb", line: 2, duration: nil, layer: "unit")
    get repository_path(repository, spec_directory: "spec/unit10", layer: "unit", limit: 1)
    expect(panel.all("tbody tr").map { it.first("td").text.strip }).not_to include("spec/unit10")
    open_text = page.find("#spec-directory-files").text.gsub(/\s+/, " ")
    expect(open_text).to include("durations cover")
    expect(open_text).not_to include(sentence)

    # Unasked, a listed area still carries it.
    get repository_path(repository, spec_directory: "spec/unit00")
    observe(run, path: "spec/unit00/b_spec.rb", line: 2, duration: nil, layer: "unit")
    get repository_path(repository, spec_directory: "spec/unit00")
    expect(page.find("#spec-directory-files").text.gsub(/\s+/, " ")).to include(sentence)
  end

  # @intent: { entity: "GET /repositories/:id", action: "route from a layer to its areas", behavior: "Spec directories by declared layer links each layer to the spec directory ranking by that layer on the spec-directory-durations anchor, keeping other asks, while the Time by declared layer slowest-examples links are unchanged", layer: "request" }
  it "offers a directories route per layer beside the slowest-examples links" do
    get repository_path(repository, branch: "main", commit_sha: "paneldir0001", layer: "request")

    names = page.all("#layer-durations a")
    directories = page.all("#layer-durations-directories a")

    expect(names.map(&:text)).to eq(%w[unit request undeclared])
    expect(names.map { it[:href] }).to all(end_with("#slowest-examples"))
    expect(directories.map(&:text)).to eq(names.map(&:text))
    directories.each do |link|
      expect(link[:href]).to include("layer=#{link.text}").and end_with("#spec-directory-durations")
      expect(link[:href]).to include("branch=main").and include("commit_sha=paneldir0001")
    end
    expect(directories.select { it[:"aria-current"] == "true" }.map(&:text)).to eq(["request"])
    expect(names.select { it[:"aria-current"] == "true" }.map(&:text)).to eq(["request"])
  end
end
