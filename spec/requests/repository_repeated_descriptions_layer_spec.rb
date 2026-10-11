# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the "Descriptions this run recorded more than once" panel (SPGD-1763): groups are
# descriptions repeated WITHIN one declared layer, ranked by that layer's time, in the query before the
# grouping. The layer is what each example's `@intent` declared, never inferred from the path. The
# no-ask page must be unchanged.
RSpec.describe "Repository repeated descriptions — ?layer=", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def page = Capybara.string(response.body)

  def panel = page.find("#repeated-descriptions")

  def layer_note = panel.find("#repeated-descriptions-layer").text.gsub(/\s+/, " ").strip

  def clear_link = page.first("#repeated-descriptions-clear-layer", minimum: 0)

  def row_names = panel.all("tbody tr").map { it.all("td").first.text.strip.sub(/\s+in .*\z/m, "") }

  def observe(run, name:, line:, duration:, layer:)
    run.spec_observations.create!(
      repository: run.repository, example_id: "./spec/models/a_spec.rb[1:#{line}]",
      file_path: "spec/models/a_spec.rb", spec_file_path: "spec/models/a_spec.rb",
      line_number: line, status: "unannotated", duration_seconds: duration, name: name,
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "descpanel001", branch: "main",
                               total_specs_count: 30, duration_seconds: 90.0)
    line = 0
    11.times { |g| 2.times { observe(test_run, name: format("unit group %02d", g), line: (line += 1), duration: 7.0, layer: "unit") } }
    # Three timed, one untimed: the drill-in's partial-coverage sentence is the one that cross-references the row.
    3.times { observe(test_run, name: "A request loop", line: (line += 1), duration: 4.0, layer: "request") }
    observe(test_run, name: "A request loop", line: (line += 1), duration: nil, layer: "request")
    test_run
  end

  # @intent: { entity: "GET /repositories/:id", action: "find repeated descriptions within a layer", behavior: "?layer=request lists the description repeated inside the request layer with the layer's own counts and a caption naming the layer, where the unasked panel does not show it at all", layer: "request" }
  it "groups within the layer and says so" do
    get repository_path(repository)
    expect(row_names).not_to include("A request loop")
    expect(page).not_to have_css("#repeated-descriptions-layer")

    get repository_path(repository, layer: "request")

    expect(row_names).to eq(["A request loop"])
    expect(panel.all("tbody tr").first.all("td")[1].text.strip).to eq("4")
    expect(panel.all("tbody tr").first.all("td")[2].text.strip).to include("3 of 4")
    expect(layer_note).to include("declared request").and include("repeated within that layer")
      .and include("never inferred from the path")
  end

  # @intent: { entity: "GET /repositories/:id", action: "offer a way back from the layer filter", behavior: "an active layer renders a Clear layer filter link on the repeated descriptions panel that drops only the layer and keeps other asks", layer: "request" }
  it "renders a clear link that drops only the layer" do
    get repository_path(repository, layer: "request", commit_sha: "descpanel001", branch: "main")

    expect(clear_link.text.squish).to eq("Clear layer filter")
    expect(clear_link[:href]).not_to include("layer=")
    expect(clear_link[:href]).to include("commit_sha=descpanel001").and include("branch=main")
      .and end_with("#repeated-descriptions")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state an empty layer", behavior: "a layer no example declared renders the panel with an empty-layer state and a clear link, not no panel and not the run-reported-no-descriptions state", layer: "system" }
  it "renders an empty answer for a layer nothing declared" do
    get repository_path(repository, layer: "system")

    expect(page).to have_css("#repeated-descriptions-layer-empty")
    expect(page).not_to have_css("#repeated-descriptions-unnamed")
    expect(panel.all("tbody tr")).to be_empty
    expect(clear_link.text.squish).to eq("Clear layer filter")
  end

  # @intent: { entity: "GET /repositories/:id", action: "carry the layer through the description drill-in", behavior: "opening a group under a layer keeps the layer, lists only the layer's examples, states the same-fraction sentence and the layer note, and the group's count equals the clicked row's", layer: "request" }
  it "opens a group under the layer with the same count the row states" do
    get repository_path(repository, layer: "request")
    link = panel.first("tbody tr").find("a", exact_text: "Every example under it", visible: :all)
    expect(link[:href]).to include("layer=request")
    row_count = panel.first("tbody tr").all("td")[1].text.strip.to_i

    get repository_path(repository, layer: "request", repeated_description: "A request loop")

    drill = page.find("#repeated-description-examples")
    basis = drill.find("#repeated-description-examples-basis").text.gsub(/\s+/, " ")
    expect(drill.all("tbody tr").size).to eq(row_count)
    expect(basis).to include("All 4 examples this run recorded under it")
      .and include("Durations here cover 3 of 4")
      .and include("the same fraction the row for this description states in the panel above")
      .and include("declared request")
  end

  # @intent: { entity: "GET /repositories/:id", action: "route from a layer to its repeated descriptions", behavior: "Repeated descriptions by declared layer links each layer to the repeated-descriptions anchor keeping other asks, while the slowest-examples links are unchanged", layer: "request" }
  it "offers a repeated-descriptions route per layer beside the slowest-examples links" do
    get repository_path(repository, branch: "main", commit_sha: "descpanel001", layer: "request")

    names = page.all("#layer-durations a")
    routes = page.all("#layer-durations-descriptions a")

    expect(names.map { it[:href] }).to all(end_with("#slowest-examples"))
    expect(routes.map(&:text)).to eq(names.map(&:text))
    routes.each do |link|
      expect(link[:href]).to include("layer=#{link.text}").and end_with("#repeated-descriptions")
      expect(link[:href]).to include("branch=main").and include("commit_sha=descpanel001")
    end
    expect(routes.select { it[:"aria-current"] == "true" }.map(&:text)).to eq(["request"])
    expect(names.select { it[:"aria-current"] == "true" }.map(&:text)).to eq(["request"])
  end
end
