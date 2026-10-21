# frozen_string_literal: true

require "rails_helper"

# The "Machine time by declared layer, by run" strip under "Declared layers by run" on
# repositories#show (SPGD-1829) — the TIME twin of SPGD-1819's mix strip.
#
# `layer_runtime_growth` and `layer_runtime_window_growth` compare two points; this draws every
# PLOTTED run's per-layer machine time, one chart per layer, so a step, creep and noise are
# different shapes. It inherits `SuiteTrajectory`'s cohort (a run withheld from the line is not
# drawn), never draws a point for a run with no per-example rows, and never draws a layer's
# untimed run as 0 s.
RSpec.describe "Repository Suite growth — Machine time by declared layer", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  let(:grouped_read) { /GROUP BY "spec_observations"\."test_run_id"/ }

  def panel = Capybara.string(response.body).find("#suite-trajectory")

  def strip = panel.find("#suite-trajectory-layer-time")

  # `layers` is { layer => [seconds, …] }; a nil is an untimed example.
  def run(commit, at:, layers: nil, branch: "main", total: 1_000)
    test_run = repository.test_runs.create!(commit_sha: commit, branch: branch, total_specs_count: total,
                                            annotated_specs_count: total / 4, created_at: at)
    (layers || {}).each do |layer, seconds_list|
      seconds_list.each_with_index do |seconds, line|
        test_run.spec_observations.create!(
          repository: repository, example_id: "./spec/#{layer}_spec.rb[1:#{line}]",
          file_path: "spec/#{layer}_spec.rb", spec_file_path: "spec/#{layer}_spec.rb", line_number: line + 1,
          status: "unannotated", duration_seconds: seconds, intent_layer: (layer == :undeclared ? nil : layer.to_s)
        )
      end
    end
    test_run
  end

  def timed(commit, at, request:)
    run(commit, at: at, layers: { unit: [1.0, 2.0], request: [request], system: [nil] })
  end

  describe "a plottable window whose runs recorded timed examples" do
    before do
      timed("tm000000001", 3.days.ago, request: 5.0)
      timed("tm000000002", 2.days.ago, request: 50.0)
      timed("tm000000003", 1.day.ago, request: 6.0)
    end

    # @intent: { entity: "Repository", action: "link layer time run labels", behavior: "each label cell of a layer's machine-time table links to its run by full sha anchored at summary", layer: "request" }
    it "links each machine-time table label to its run" do
      get repository_path(repository, branch: "main")

      hrefs = strip.find("#suite-trajectory-layer-time-request")
                   .all("details table tbody tr td:first-child a", visible: :all).map { |a| a[:href] }
      expect(hrefs).to eq(%w[tm000000001 tm000000002 tm000000003].map do |sha|
        repository_path(repository, branch: "main", commit_sha: sha, anchor: "summary")
      end)
    end

    # @intent: { entity: "Repository", action: "draw the layer time strip", behavior: "the Suite growth panel draws one machine-time chart per layer that has timed runs, with the machine-time-not-wall-clock caption and an accessible summary", layer: "request" }
    it "draws one chart per timed layer with the caption and a text summary" do
      get repository_path(repository, branch: "main")

      expect(strip.find("h3").text).to eq("Machine time by declared layer, by run")
      expect(strip).to have_css("#suite-trajectory-layer-time-unit")
      expect(strip).to have_css("#suite-trajectory-layer-time-request")
      # `system` has examples but none timed, so it has no figure to chart — never a 0 s line.
      expect(strip).to have_no_css("#suite-trajectory-layer-time-system")
      expect(strip).to have_no_css("#suite-trajectory-layer-time-integration")
      request_rows = strip.all("#suite-trajectory-layer-time-request tbody tr", visible: :all)
      expect(request_rows.map { |row| row.all("td", visible: :all).first.text(:all) }).to eq(%w[tm00000 tm00000 tm00000])
      expect(strip.find("#suite-trajectory-layer-time-caption").text.squish).to eq(
        "SUM of example durations — machine time, not wall clock; do not difference across rows whose " \
        "shard_count / timed_shard_count differ. Each chart is one declared layer on its own axis; only runs " \
        "where that layer had a timed example are points."
      )
      summary = strip.find("p.sr-only", visible: :all).text(:all)
      expect(summary).to include("across the plotted runs on main")
      expect(summary).to include("request 5.0 s in the oldest drawn run and 6.0 s in the newest")
      expect(summary).to include("unit 3.0 s")
      expect(strip).to have_no_css("#suite-trajectory-layer-time-skipped")
    end

    # @intent: { entity: "Repository", action: "pay one grouped read", behavior: "the layer time strip adds no read of its own: the plotted runs are primed by the one grouped spec_observations read that also serves the mix strip, at 3 and 18 plotted runs", layer: "request" }
    it "primes the plotted runs with exactly one grouped spec_observations read, however many are plotted" do
      get repository_path(repository, branch: "main")
      one = observation_reads { get repository_path(repository, branch: "main") }.grep(grouped_read)
      expect(one.length).to eq(1)
      expect(one.first).to include("run_layer_request_seconds")

      15.times { |i| timed("more#{i.to_s.rjust(7, '0')}", (10 + i).hours.ago, request: i + 1.0) }
      get repository_path(repository, branch: "main")
      expect(strip.all("#suite-trajectory-layer-time-request tbody tr", visible: :all).size).to eq(18)
      many = observation_reads { get repository_path(repository, branch: "main") }.grep(grouped_read)
      expect(many.length).to eq(1)
    end
  end

  describe "runs without per-example rows or without timing" do
    # @intent: { entity: "Repository", action: "skip unrecorded runs", behavior: "a plotted run with no per-example rows contributes no point to any layer chart and the strip states how many were skipped and why", layer: "request" }
    it "skips an unrecorded run with a stated reason and draws no point for it" do
      timed("sk000000001", 3.days.ago, request: 5.0)
      run("sk000000002", at: 2.days.ago)
      timed("sk000000003", 1.day.ago, request: 7.0)

      get repository_path(repository, branch: "main")

      rows = strip.all("#suite-trajectory-layer-time-request tbody tr", visible: :all)
      expect(rows.size).to eq(2)
      expect(strip.find("#suite-trajectory-layer-time-skipped").text.squish)
        .to include("1 of the 3 plotted runs is not drawn here for having no recorded per-example rows")
    end

    # @intent: { entity: "Repository", action: "omit an empty time strip", behavior: "no machine-time strip renders when no plotted run has a timed example, while the Suite growth line still does", layer: "request" }
    it "renders no strip when no plotted run has any timing" do
      3.times { |i| run("nt00000000#{i}", at: (3 - i).days.ago, layers: { unit: [nil, nil] }) }

      get repository_path(repository, branch: "main")

      expect(panel).to have_css("#suite-trajectory-chart")
      expect(panel).to have_no_css("#suite-trajectory-layer-time")
      expect(response.body).not_to include("Machine time by declared layer")
    end

    # @intent: { entity: "Repository", action: "never chart one point", behavior: "a layer timed in only one plotted run is named as not charted rather than drawn as a flat line", layer: "request" }
    it "names a layer timed in a single plotted run instead of drawing a flat line" do
      run("one0000000a", at: 3.days.ago, layers: { unit: [1.0], request: [2.0] })
      run("one0000000b", at: 2.days.ago, layers: { unit: [2.0], request: [nil] })
      run("one0000000c", at: 1.day.ago, layers: { unit: [3.0] })

      get repository_path(repository, branch: "main")

      expect(strip).to have_css("#suite-trajectory-layer-time-unit")
      expect(strip).to have_no_css("#suite-trajectory-layer-time-request")
      expect(strip.find("#suite-trajectory-layer-time-thin").text.squish).to include("request")
    end
  end

  describe "a branch that is not plottable" do
    # @intent: { entity: "Repository", action: "pay nothing when not plottable", behavior: "a page whose Suite growth line is not plottable draws no machine-time strip and issues no grouped layer read", layer: "request" }
    it "draws no strip and pays no grouped layer read" do
      timed("solo0000001", 1.day.ago, request: 2.0)

      get repository_path(repository, branch: "main")
      reads = observation_reads { get repository_path(repository, branch: "main") }

      expect(panel).to have_no_css("#suite-trajectory-layer-time")
      expect(reads.grep(grouped_read)).to be_empty
    end
  end
end
