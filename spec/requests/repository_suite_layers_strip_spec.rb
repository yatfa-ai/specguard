# frozen_string_literal: true

require "rails_helper"

# The "Declared layers by run" strip under the Suite growth line on repositories#show (SPGD-1819).
#
# `layer_growth` is two endpoints and cannot say WHEN the request layer shifted; this draws the mix
# of every PLOTTED run, one bar each, so a step, a creep and a rise-and-fall-back are different
# shapes. It inherits `SuiteTrajectory`'s comparability rule — a run withheld from the line is not
# drawn — and it never draws an empty bar for a run that stored no per-example rows.
RSpec.describe "Repository Suite growth — Declared layers by run", type: :request do
  before { @user = sign_in_via_github }

  let(:repository) { create_repository(user: @user) }

  def panel = Capybara.string(response.body).find("#suite-trajectory")

  def strip = panel.find("#suite-trajectory-layers")

  def run(commit, at:, branch: "main", total: 1_000, layers: nil)
    test_run = repository.test_runs.create!(commit_sha: commit, branch: branch, total_specs_count: total,
                                            annotated_specs_count: total / 4, created_at: at)
    (layers || {}).each do |layer, count|
      count.times do |line|
        test_run.spec_observations.create!(
          repository: repository, example_id: "./spec/#{layer}_spec.rb[1:#{line}]",
          file_path: "spec/#{layer}_spec.rb", spec_file_path: "spec/#{layer}_spec.rb", line_number: line + 1,
          status: "unannotated", intent_layer: (layer == :undeclared ? nil : layer.to_s)
        )
      end
    end
    test_run
  end

  def mixed(commit, at, request:)
    run(commit, at: at, layers: { unit: 3, request: request, undeclared: 1 })
  end

  describe "a plottable branch window whose runs recorded their examples" do
    before do
      mixed("layer0000001", 3.days.ago, request: 1)
      mixed("layer0000002", 2.days.ago, request: 4)
      mixed("layer0000003", 1.day.ago, request: 1)
    end

    # @intent: {"entity": "Repository", "action": "draw the layer strip", "behavior": "the Suite growth panel draws one declared-layer bar per plotted run, oldest first, with one shared key and an accessible summary naming every layer", "layer": "request"}
    it "draws one bar per plotted run, oldest first, with one key and a text summary naming the layers" do
      get repository_path(repository, branch: "main")

      bars = strip.all("ol li")
      expect(bars.map { |li| li["data-commit-sha"] }).to eq(%w[layer0000001 layer0000002 layer0000003])
      # Each row's sha cell is the family's read link into that run: the FULL sha in the href
      # (`latest_test_run_for_commit` matches exactly, so a seven-character href would resolve nil
      # and silently fall back to the newest run), recomputed from the router rather than through
      # `drill_down_path`, which reads controller ivars this spec does not have. The example asks
      # for the branch by name, so the carried branch ask rides beside the sha ask.
      bars.each do |li|
        sha = li["data-commit-sha"]
        expect(li).to have_link(sha.first(7),
                                href: repository_path(repository, commit_sha: sha, anchor: "summary",
                                                                     branch: "main"))
      end
      expect(strip.all("ol li span.rc-stack", count: 3).size).to eq(3)
      # The middle run's bar carries its own counts, so a rise-and-fall is a different shape per bar.
      expect(bars[1].find("span.rc-stack")["aria-label"]).to eq("unit 3, request 4, undeclared 1")
      expect(bars[0].find("span.rc-stack")["aria-label"]).to eq("unit 3, request 1, undeclared 1")
      # ONE key for the strip, not one per bar, naming all five layers.
      expect(strip.all("ul.rc-key", count: 1).size).to eq(1)
      expect(strip.all("ul.rc-key li").map(&:text)).to eq(%w[unit integration request system undeclared])
      summary = strip.find("p.sr-only", visible: :all).text(:all)
      expect(summary).to include("3 runs on main")
      %w[unit integration request system undeclared].each { |layer| expect(summary).to include(layer) }
      expect(strip).to have_no_css("#suite-trajectory-layers-skipped")
    end

    # @intent: {"entity": "Repository", "action": "pay one layer read", "behavior": "the layer strip primes the plotted runs with one grouped spec_observations read, however many runs are plotted", "layer": "request"}
    it "primes the plotted runs with exactly one grouped spec_observations read" do
      get repository_path(repository, branch: "main")
      one = observation_reads { get repository_path(repository, branch: "main") }
              .grep(/GROUP BY "spec_observations"\."test_run_id"/)
      expect(one.length).to eq(1)

      15.times { |i| mixed("more#{i.to_s.rjust(8, '0')}", (10 + i).hours.ago, request: i) }
      get repository_path(repository, branch: "main")
      expect(strip.all("ol li").size).to eq(18)
      many = observation_reads { get repository_path(repository, branch: "main") }
               .grep(/GROUP BY "spec_observations"\."test_run_id"/)
      expect(many.length).to eq(1)
    end
  end

  describe "runs that stored no per-example rows" do
    # @intent: {"entity": "Repository", "action": "skip unrecorded runs", "behavior": "a plotted run with no per-example rows is not drawn as an empty bar and the strip says how many were skipped and why", "layer": "request"}
    it "skips them with a stated reason instead of drawing an empty bar" do
      mixed("skip00000001", 3.days.ago, request: 2)
      run("skip00000002", at: 2.days.ago)
      mixed("skip00000003", 1.day.ago, request: 3)

      get repository_path(repository, branch: "main")

      expect(strip.all("ol li").map { |li| li["data-commit-sha"] }).to eq(%w[skip00000001 skip00000003])
      expect(strip.find("#suite-trajectory-layers-skipped").text.squish)
        .to include("1 of the 3 plotted runs is not drawn here for having no recorded per-example rows")
    end

    # @intent: {"entity": "Repository", "action": "omit an empty strip", "behavior": "no declared-layers strip renders when no plotted run recorded a mix, while the Suite growth line still does", "layer": "request"}
    it "renders no strip at all when no plotted run has a mix" do
      run("none00000001", at: 3.days.ago)
      run("none00000002", at: 2.days.ago)
      run("none00000003", at: 1.day.ago)

      get repository_path(repository, branch: "main")

      expect(panel).to have_css("#suite-trajectory-chart")
      expect(panel).to have_no_css("#suite-trajectory-layers")
      expect(response.body).not_to include("Declared layers by run")
    end
  end

  describe "runs the line withholds" do
    # @intent: {"entity": "Repository", "action": "draw only plotted runs", "behavior": "a run withheld from the Suite growth line for being assembled differently is not drawn on the layer strip either", "layer": "request"}
    it "does not draw a run the line withholds" do
      mixed("with00000001", 4.days.ago, request: 1)
      mixed("with00000002", 3.days.ago, request: 2)
      mixed("with00000003", 2.days.ago, request: 3)
      # Part-way sharded: one of the shards the cohort would carry, so it is withheld from the line.
      partial = run("with00000004", at: 1.day.ago, layers: { unit: 1, request: 9 })
      partial.update_columns(ci_run_id: "gha-partial")
      partial.test_run_shards.create!(shard_id: "0", total_specs_count: 10, annotated_specs_count: 1)

      get repository_path(repository, branch: "main")

      expect(panel.find("#suite-trajectory-basis").text.squish).to include("withheld")
      expect(strip.all("ol li").map { |li| li["data-commit-sha"] })
        .to eq(%w[with00000001 with00000002 with00000003])
    end
  end

  describe "a branch that is not plottable" do
    # @intent: {"entity": "Repository", "action": "pay nothing when not plottable", "behavior": "a page whose Suite growth line is not plottable draws no layer strip and issues no grouped layer read", "layer": "request"}
    it "draws no strip and pays no grouped layer read" do
      mixed("solo0000001", 1.day.ago, request: 2)

      get repository_path(repository, branch: "main")
      reads = observation_reads { get repository_path(repository, branch: "main") }

      expect(panel).to have_no_css("#suite-trajectory-layers")
      expect(reads.grep(/GROUP BY "spec_observations"\."test_run_id"/)).to be_empty
    end
  end
end
