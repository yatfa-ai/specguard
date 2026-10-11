# frozen_string_literal: true

require "rails_helper"

# `?layer=` on the "Slowest tests" panel (SPGD-1685). The layer is what each example's `@intent`
# declared, never inferred from the path. The no-ask page must be unchanged.
RSpec.describe "Repository slowest tests — ?layer=", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def page = Capybara.string(response.body)

  def panel = page.find("#slowest-examples")

  def basis = panel.find("#slowest-examples-basis").text.gsub(/\s+/, " ").strip

  def observe(run, line:, duration:, layer:, path: "spec/mixed/#{layer || 'none'}_spec.rb")
    run.spec_observations.create!(
      repository: run.repository, example_id: "./#{path}[1:#{line}]", file_path: path, spec_file_path: path,
      line_number: line, status: "unannotated", duration_seconds: duration, name: "#{layer} example #{line}",
      outcome: "passed", intent_layer: layer
    )
  end

  let!(:run) do
    test_run = create_test_run(repository: repository, commit_sha: "panellayer01", branch: "main",
                               total_specs_count: 20, duration_seconds: 30.0)
    12.times { |i| observe(test_run, line: i + 1, duration: 50.0 - i, layer: "unit") }
    [9.0, 4.5].each_with_index { |d, i| observe(test_run, line: 100 + i, duration: d, layer: "request") }
    observe(test_run, line: 110, duration: nil, layer: "request")
    observe(test_run, line: 140, duration: 8.0, layer: nil, path: "spec/requests/login_spec.rb")
    test_run
  end

  def clear_link = page.first("#slowest-examples-clear-layer a", minimum: 0)

  # @intent: { entity: "GET /repositories/:id", action: "narrow the slowest tests panel to a layer", behavior: "?layer=request lists only request-layer rows and the basis sentence names the layer and its own counts", layer: "request" }
  it "lists only the asked layer's tests and names the layer in the basis sentence" do
    get repository_path(repository, layer: "request")

    expect(panel.all("tbody tr").map { it.all("td")[1].text.strip }).to eq(%w[request request])
    expect(basis).to include("request-layer").and include("2 of 3").and include("declared request")
    expect(basis).to include("never inferred from the path")
  end

  # @intent: { entity: "GET /repositories/:id", action: "offer a way back from the layer filter", behavior: "an active layer renders a Clear layer filter link that drops the layer and keeps the other asks", layer: "request" }
  it "renders a clear link that drops only the layer" do
    get repository_path(repository, layer: "request", commit_sha: "panellayer01", branch: "main")

    href = clear_link[:href]
    expect(clear_link.text).to eq("Clear layer filter")
    expect(href).not_to include("layer=")
    expect(href).to include("commit_sha=panellayer01").and include("branch=main").and end_with("#slowest-examples")
  end

  # @intent: { entity: "GET /repositories/:id", action: "link layer names to the filter", behavior: "each layer name in Time by declared layer links to its layer filter on the slowest tests anchor and preserves the other active asks", layer: "request" }
  it "links each layer name in the Time by declared layer line to the filter, preserving other asks" do
    get repository_path(repository, spec_file: "spec/mixed/unit_spec.rb", branch: "main", commit_sha: "panellayer01")

    links = page.all("#layer-durations a").to_h { [it.text, it[:href]] }
    expect(links.keys).to eq(%w[unit request undeclared])
    links.each do |name, href|
      expect(href).to include("layer=#{name}").and end_with("#slowest-examples")
      expect(href).to include("spec_file=").and include("branch=main").and include("commit_sha=panellayer01")
    end
    # The figures are the ones the plain label used to join into a sentence, now one table row per
    # layer: the same `layer_durations_parts` source, so a layer's row says what its clause said.
    table = page.find("#layer-durations")
    cells = table.all("tbody tr").to_h { |row| row.all("td").first(3).then { |name, time, timed| [name.text.squish, [time.text.squish, timed.text.squish]] } }
    expect(cells["request"]).to eq(["13.50s", "2 of 3"])
    SpecDirectoryDurations.layer_durations_parts(run.layer_durations, run.layer_counts).each do |layer, figures|
      expect(figures).to include(cells.fetch(layer.to_s).last.sub(" of ", " of ")) if figures.include?("timed")
    end
  end

  # @intent: { entity: "GET /repositories/:id", action: "keep the layer when drilling", behavior: "with a layer active, opening a spec file keeps the layer in the link", layer: "request" }
  it "carries an active layer through the other drill-down links" do
    get repository_path(repository, layer: "request")

    expect(panel.first("tbody tr a[href*='spec_file=']")[:href]).to include("layer=request")
  end

  # @intent: { entity: "GET /repositories/:id", action: "state an empty layer", behavior: "a layer no example declared renders the panel with an empty-layer sentence and a clear link, not no panel", layer: "request" }
  it "renders the panel with an empty answer for a layer nothing declared" do
    get repository_path(repository, layer: "system")

    expect(page).to have_css("#slowest-examples")
    expect(panel.all("tbody tr")).to be_empty
    expect(basis).to include("No example of this run declared system")
    expect(clear_link.text).to eq("Clear layer filter")
  end

  # @intent: { entity: "GET /repositories/:id", action: "ignore malformed layer asks", behavior: "an unknown, array or blank layer renders the same panel as no ask and no clear link", layer: "request" }
  it "reads malformed asks as no ask, byte-identical to the no-ask page apart from the CSRF token" do
    # A warm-up read first: the sign-in flash is one-shot and would otherwise sit on the first body only.
    get repository_path(repository)
    get repository_path(repository)
    baseline = response.body.gsub(/csrf-token" content="[^"]*"/, "")

    ["?layer=bogus", "?layer[]=request", "?layer=", "?layer=%00"].each do |suffix|
      get "#{repository_path(repository)}#{suffix}"

      expect(response).to have_http_status(:ok), suffix
      expect(response.body.gsub(/csrf-token" content="[^"]*"/, "")).to eq(baseline), suffix
    end
  end

  # @intent: { entity: "GET /repositories/:id", action: "leave the unasked page unchanged", behavior: "without a layer ask the basis sentence is the run-wide one, no clear link renders and layer links appear only on the Time by declared layer names", layer: "request" }
  it "leaves the no-ask panel as it was" do
    get repository_path(repository)

    expect(basis).to start_with("The 10 slowest tests of the run named above")
    expect(basis).not_to include("-layer")
    expect(clear_link).to be_nil
    expect(panel.all("a[href*='layer=']")).to be_empty
  end
end
