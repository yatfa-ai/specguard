# frozen_string_literal: true

require "rails_helper"

# The request+system share on the show page's "Declared layers" panel (SPGD-1882), stated as two
# LABELED LEVELS and never a delta: this run's share beside its bar, and the previous run's share
# inside the comparable-gated "Since …" line. Both are `test_run_pyramid_share`'s output verbatim —
# the one seam the repositories grid card and `?sort=pyramid` read.
#
# Every operand of the formula is visible in the fixtures (unit, integration, request AND system
# each carry a distinct count), so dropping a key from the numerator or the denominator, or
# swapping the two runs, flips an asserted string.
RSpec.describe "Declared layers panel — request+system share", type: :request do
  LATEST = "late00000000882"
  PREVIOUS = "prev00000000882"

  before { @user = sign_in_via_github }

  def new_repository
    @seq = (@seq || 0) + 1
    create_repository(user: @user, github_full_name: "acme/pyramid-#{@seq}")
  end

  def layer_specs(counts)
    line = 0
    counts.flat_map do |layer, count|
      Array.new(count) do
        line += 1
        if layer == :undeclared
          unannotated_spec(file_path: "spec/models/a_spec.rb", line_number: line)
        else
          annotated_spec(file_path: "spec/models/a_spec.rb", line_number: line, layer: layer.to_s,
                         name: "#{layer} example #{line}")
        end
      end
    end
  end

  def ingest(repository, sha, counts: nil, total: nil, at: nil)
    specs = counts && layer_specs(counts)
    payload = { commit_sha: sha, branch: "main", total_specs_count: total || specs&.size || 0,
                annotated_specs_count: 0, duration_seconds: 60.0 }
    options = specs ? { specs: specs.map(&:deep_stringify_keys) } : {}
    run = Ingest::RunRecorder.record(repository, payload, **options)
    TestRun.where(id: run.id).update_all(created_at: at) if at
    run
  end

  def shown(repository)
    get repository_path(repository)
    Capybara.string(response.body)
  end

  LATEST_SENTENCE = "Request+system 50.0% of declared layers — 3 of 6 declared tests."
  PREVIOUS_SENTENCE = "Request+system 33.3% of declared layers — 1 of 3 declared tests."

  def two_runs(previous: { unit: 1, integration: 1, request: 1, system: 0 },
               latest: { unit: 2, integration: 1, request: 1, system: 2 })
    repository = new_repository
    ingest(repository, PREVIOUS, counts: previous, at: 2.hours.ago)
    ingest(repository, LATEST, counts: latest, at: 1.minute.ago)
    repository
  end

  # @intent: {"entity": "TestRun", "action": "state pyramid share", "behavior": "the Declared layers panel prints this run's request+system share beside its bar and the previous run's share, prefixed That run read, inside the Since line", "layer": "request"}
  it "states this run's share beside the bar and the previous run's inside the Since line" do
    page = shown(two_runs)

    layers = page.find("#layers")
    expect(layers.find("#layer-pyramid-share").text.squish).to eq(LATEST_SENTENCE)
    since = layers.find("#layer-run-growth")
    expect(since.text.squish).to include("That run read #{PREVIOUS_SENTENCE}")
    # The previous sentence is labeled by its run and never reads as a movement.
    expect(since.text.squish).not_to include("#{LATEST_SENTENCE}")
    expect(since.all("a").size).to eq(1)
  end

  # @intent: {"entity": "TestRun", "action": "state pyramid share", "behavior": "swapping which run each sentence reads, or changing one layer's count, changes the printed share", "layer": "request"}
  it "reads each sentence from its own run and every layer key moves the figure" do
    # system 2 -> 0 on the latest run: 50.0% -> 16.7%, "3 of 6" -> "1 of 6".
    page = shown(two_runs(latest: { unit: 2, integration: 1, request: 1, system: 0 }))
    expect(page.find("#layer-pyramid-share").text.squish)
      .to eq("Request+system 25.0% of declared layers — 1 of 4 declared tests.")

    # unit 2 -> 0: the denominator 6 -> 4 (unit is in the denominator).
    page = shown(two_runs(latest: { unit: 0, integration: 1, request: 1, system: 2 }))
    expect(page.find("#layer-pyramid-share").text.squish)
      .to eq("Request+system 75.0% of declared layers — 3 of 4 declared tests.")

    # integration 1 -> 0 on the previous run: integration is in the denominator, not the numerator.
    page = shown(two_runs(previous: { unit: 1, integration: 0, request: 1, system: 0 }))
    expect(page.find("#layer-run-growth").text.squish)
      .to include("That run read Request+system 50.0% of declared layers — 1 of 2 declared tests.")
  end

  # @intent: {"entity": "TestRun", "action": "state pyramid share", "behavior": "a run declaring only unit tests prints a real 0.0% share with its denominator", "layer": "request"}
  it "prints a measured zero as 0.0% over its denominator" do
    page = shown(two_runs(latest: { unit: 3, integration: 1 }))

    expect(page.find("#layer-pyramid-share").text.squish)
      .to eq("Request+system 0.0% of declared layers — 0 of 4 declared tests.")
  end

  # @intent: {"entity": "TestRun", "action": "state pyramid share", "behavior": "a previous run with nothing declared keeps the growth line but prints no previous-run sentence", "layer": "request"}
  it "omits the previous sentence, not the growth line, when the previous run declared nothing" do
    page = shown(two_runs(previous: { undeclared: 3 }))

    since = page.find("#layer-run-growth")
    expect(since.text.squish).to include("Since #{PREVIOUS.first(7)} on main:")
    expect(since.text.squish).not_to include("That run read")
    expect(page.find("#layer-pyramid-share").text.squish).to eq(LATEST_SENTENCE)
  end

  # @intent: {"entity": "TestRun", "action": "state pyramid share", "behavior": "when the pair is not comparable the growth line and the previous sentence are both absent while this run's share still stands", "layer": "request"}
  it "states one level when the pair is incomparable" do
    repository = new_repository
    ingest(repository, PREVIOUS, total: 0, at: 2.hours.ago)
    ingest(repository, LATEST, counts: { unit: 2, integration: 1, request: 1, system: 2 }, at: 1.minute.ago)

    page = shown(repository)

    expect(page).to have_no_css("#layer-run-growth")
    expect(page.text).not_to include("That run read")
    expect(page.find("#layer-pyramid-share").text.squish).to eq(LATEST_SENTENCE)
  end

  # @intent: {"entity": "TestRun", "action": "state pyramid share", "behavior": "a run with no per-example rows prints the empty state and no share sentence", "layer": "request"}
  it "prints no sentence on a run with no per-example rows" do
    repository = new_repository
    ingest(repository, LATEST, total: 5)

    page = shown(repository)

    expect(page).to have_no_css("#layer-pyramid-share")
    expect(page.find("#layers")).to have_text("No per-example rows")
  end

  # @intent: {"entity": "TestRun", "action": "state pyramid share", "behavior": "the share sentences add no spec_observations read: the count is the same at three examples and at many more", "layer": "request"}
  it "adds no spec_observations reads as the run grows" do
    small = two_runs
    small_reads = queries_against("spec_observations") { get repository_path(small) }.size

    large = two_runs(previous: { unit: 11, integration: 7, request: 5, system: 3 },
                     latest: { unit: 20, integration: 9, request: 8, system: 6 })
    large_reads = queries_against("spec_observations") { get repository_path(large) }.size

    expect(small_reads).to be_positive
    expect(large_reads).to eq(small_reads)
  end
end
