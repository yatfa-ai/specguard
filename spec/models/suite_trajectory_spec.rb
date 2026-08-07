# frozen_string_literal: true

require "rails_helper"

# Which runs of a branch's history may be drawn as one line.
#
# The runs here are built directly and primed with `preload_shard_count`, which is the shape
# `Repository#suite_size_trajectory` hands over — that method's own query, ordering and priming are
# pinned in spec/models/repository_spec.rb, and the page-level behaviour in
# spec/requests/repository_suite_trajectory_spec.rb. What is asked here is only the selection rule.
RSpec.describe SuiteTrajectory do
  def point(repository, commit, total:, shards: 0, at: 1.hour.ago)
    repository.test_runs.create!(commit_sha: commit, branch: "main", total_specs_count: total,
                                 created_at: at)
                        .preload_shard_count(shards)
  end

  def trajectory(runs, branch: "main") = described_class.new(runs: runs, branch: branch)

  it "plots every run when they all measured a suite the same way" do
    repository = create_repository
    runs = [point(repository, "aaaaaaa", total: 1_000, at: 3.days.ago),
            point(repository, "bbbbbbb", total: 1_020, at: 2.days.ago),
            point(repository, "ccccccc", total: 1_047, at: 1.day.ago)]

    series = trajectory(runs)

    expect(series).to be_plottable
    expect(series.plotted.map(&:commit_sha)).to eq(%w[aaaaaaa bbbbbbb ccccccc])
    expect(series.values).to eq([1_000, 1_020, 1_047])
    expect(series.minimum).to eq(1_000)
    expect(series.maximum).to eq(1_047)
    expect(series.withheld_count).to eq(0)
  end

  # The same question `TestRun#suite_size_measured?` answers for the Overview's delta, asked of
  # every row instead of two. A zero is a count and not a measurement, and a line dropping to it
  # would draw a suite that was deleted and restored.
  it "withholds a run that reported no tests" do
    repository = create_repository
    runs = [point(repository, "aaaaaaa", total: 1_000, at: 3.days.ago),
            point(repository, "zeroooo", total: 0, at: 2.days.ago),
            point(repository, "ccccccc", total: 1_047, at: 1.day.ago)]

    series = trajectory(runs)

    expect(series.plotted.map(&:commit_sha)).to eq(%w[aaaaaaa ccccccc])
    expect(series.withheld_unmeasured.map(&:commit_sha)).to eq(%w[zeroooo])
    expect(series.withheld_composition).to be_empty
  end

  # `total_specs_count` is nullable (default 0, no `null: false`), and a NULL is "nothing was
  # reported" rather than a suite of zero.
  it "withholds a run whose count is NULL" do
    repository = create_repository
    nulled = point(repository, "nullcnt", total: 0, at: 2.days.ago)
    nulled.update_columns(total_specs_count: nil)
    runs = [point(repository, "aaaaaaa", total: 1_000, at: 3.days.ago),
            nulled.reload.preload_shard_count(0),
            point(repository, "ccccccc", total: 1_047, at: 1.day.ago)]

    expect(trajectory(runs).withheld_unmeasured.map(&:commit_sha)).to eq(%w[nullcnt])
  end

  # == The cliff
  #
  # The state the whole class exists for. A four-shard run reads at a quarter of its own suite for
  # most of its build, so plotted beside its complete neighbours it is a drop to −75% and a
  # recovery — a mass test deletion and restoration, neither of which any commit made.
  describe "when a run was assembled differently from the rest" do
    it "withholds the in-flight fragment rather than drawing a cliff" do
      repository = create_repository
      runs = [point(repository, "whole01", total: 20_000, shards: 4, at: 3.days.ago),
              point(repository, "whole02", total: 20_010, shards: 4, at: 2.days.ago),
              point(repository, "infligh", total: 5_010, shards: 1, at: 1.minute.ago)]

      series = trajectory(runs)

      expect(series.plotted.map(&:commit_sha)).to eq(%w[whole01 whole02])
      expect(series.withheld_composition.map(&:commit_sha)).to eq(%w[infligh])
      # The fragment's figure must not reach the axis: a floor of 5,010 is the cliff drawn as a
      # scale even when the point itself is gone.
      expect(series.minimum).to eq(20_000)
    end

    # The permanent form. A job cancelled after two of four shards leaves that half-sized row in the
    # history forever, so this is not a window that closes on its own.
    it "withholds a job cancelled part-way through" do
      repository = create_repository
      runs = [point(repository, "whole01", total: 20_000, shards: 4, at: 3.days.ago),
              point(repository, "cancell", total: 10_000, shards: 2, at: 2.days.ago),
              point(repository, "whole02", total: 20_010, shards: 4, at: 1.day.ago)]

      expect(trajectory(runs).plotted.map(&:commit_sha)).to eq(%w[whole01 whole02])
    end

    # The reading that first suggests itself — "compare everything to the latest run" — is wrong in
    # exactly this state, and wrong in the worst direction: it would withhold the twelve complete
    # runs and plot the fragment alone. The cohort rule inverts correctly, because a fragment is a
    # cohort of one.
    it "does not anchor on the latest run when the latest run is the odd one out" do
      repository = create_repository
      runs = 5.times.map { |i| point(repository, "whole0#{i}", total: 20_000 + i, shards: 4, at: (6 - i).days.ago) }
      runs << point(repository, "infligh", total: 5_010, shards: 1, at: 1.minute.ago)

      series = trajectory(runs)

      expect(series.plotted.size).to eq(5)
      expect(series.plotted.map(&:commit_sha)).not_to include("infligh")
    end

    # A tie has to break somewhere, and it breaks towards the composition CI is reporting now — the
    # cohort holding the most recent run. Anything else would freeze the chart on a shard layout the
    # project has already moved off.
    it "breaks an even split towards the cohort holding the most recent run" do
      repository = create_repository
      runs = [point(repository, "oldwy01", total: 1_000, shards: 2, at: 4.days.ago),
              point(repository, "oldwy02", total: 1_010, shards: 2, at: 3.days.ago),
              point(repository, "newwy01", total: 4_000, shards: 8, at: 2.days.ago),
              point(repository, "newwy02", total: 4_010, shards: 8, at: 1.day.ago)]

      expect(trajectory(runs).plotted.map(&:commit_sha)).to eq(%w[newwy01 newwy02])
    end

    # The entire existing corpus: a laptop `bundle exec rspec`, or any CI provider that named no
    # `ci_run_id`. Those rows record no shards at all, were written once and never re-derived, so
    # they were always comparable — the guard must not have quietly switched the chart off for them.
    it "plots the unsharded corpus, which is every run there has ever been" do
      repository = create_repository
      runs = [point(repository, "plain01", total: 1_000, at: 3.days.ago),
              point(repository, "plain02", total: 1_047, at: 2.days.ago)]

      series = trajectory(runs)

      expect(series.plotted.size).to eq(2)
      # No composition to state. "the same 0 shard reports" would describe a run that arrived whole
      # as a delivery that lost everything.
      expect(series.cohort_description).to be_nil
    end

    it "names the cohort's composition when there is one to name" do
      repository = create_repository
      runs = [point(repository, "whole01", total: 20_000, shards: 4, at: 2.days.ago),
              point(repository, "whole02", total: 20_010, shards: 4, at: 1.day.ago)]

      expect(trajectory(runs).cohort_description).to eq("assembled from the same 4 shard reports")
    end

    it "inflects a one-shard cohort rather than bolting an s on" do
      repository = create_repository
      runs = [point(repository, "single1", total: 1_000, shards: 1, at: 2.days.ago),
              point(repository, "single2", total: 1_010, shards: 1, at: 1.day.ago)]

      expect(trajectory(runs).cohort_description).to eq("assembled from the same 1 shard report")
    end
  end

  # A line needs two points. One drawn as a line is a FLAT line, which asserts a stable suite —
  # the one claim a history this thin cannot make.
  describe "when there is not enough to draw" do
    it "is not plottable on a single run" do
      repository = create_repository

      series = trajectory([point(repository, "onlyone", total: 1_000)])

      expect(series).not_to be_plottable
      expect(series.considered_count).to eq(1)
      expect(series.withheld_count).to eq(0)
    end

    it "is not plottable on no runs at all, and does not raise asking" do
      series = trajectory([])

      expect(series).not_to be_plottable
      expect(series.plotted).to be_empty
      expect(series.considered_count).to eq(0)
      expect(series.cohort_description).to be_nil
    end

    it "is not plottable when the one comparable run has an incomparable neighbour" do
      repository = create_repository
      runs = [point(repository, "measure", total: 1_000, at: 2.days.ago),
              point(repository, "zeroooo", total: 0, at: 1.day.ago)]

      series = trajectory(runs)

      expect(series).not_to be_plottable
      expect(series.plotted.size).to eq(1)
      expect(series.withheld_count).to eq(1)
    end

    it "is not plottable when every run reported nothing" do
      repository = create_repository
      runs = [point(repository, "zeroab1", total: 0, at: 2.days.ago),
              point(repository, "zeroab2", total: 0, at: 1.day.ago)]

      series = trajectory(runs)

      expect(series).not_to be_plottable
      expect(series.plotted).to be_empty
      expect(series.withheld_unmeasured.size).to eq(2)
    end
  end

  # The label's own denominator, on the rule `TestRun#machine_seconds_coverage` states: a label is
  # the most prominent claim a figure wears, so "15 runs" over a line through 12 is an overclaim
  # that stating the withheld count further down the page does not undo.
  describe "#coverage" do
    it "names the plotted count against the considered count when anything is withheld" do
      repository = create_repository
      runs = [point(repository, "whole01", total: 20_000, shards: 4, at: 3.days.ago),
              point(repository, "whole02", total: 20_010, shards: 4, at: 2.days.ago),
              point(repository, "infligh", total: 5_010, shards: 1, at: 1.minute.ago)]

      expect(trajectory(runs).coverage).to eq("2 of 3 runs plotted")
    end

    it "is the only case allowed to say every" do
      repository = create_repository
      runs = [point(repository, "whole01", total: 1_000, at: 2.days.ago),
              point(repository, "whole02", total: 1_010, at: 1.day.ago)]

      expect(trajectory(runs).coverage).to eq("every one of the last 2 runs plotted")
    end
  end

  # A real flat line, and a different statement from the one `plottable?` refuses: this suite WAS
  # measured across comparable runs, and it did not move.
  describe "#flat?" do
    it "is true when every plotted run measured the same suite" do
      repository = create_repository
      runs = [point(repository, "steady1", total: 1_000, at: 2.days.ago),
              point(repository, "steady2", total: 1_000, at: 1.day.ago)]

      expect(trajectory(runs)).to be_flat
    end

    it "is false the moment the suite moves by one test" do
      repository = create_repository
      runs = [point(repository, "moved01", total: 1_000, at: 2.days.ago),
              point(repository, "moved02", total: 1_001, at: 1.day.ago)]

      expect(trajectory(runs)).not_to be_flat
    end
  end

  it "reads the branch it was told, so an empty series can still name where it looked" do
    expect(described_class.new(runs: [], branch: "release/2.1").branch).to eq("release/2.1")
  end

  it "asks the database nothing — every figure is counted off the rows it was handed" do
    repository = create_repository
    runs = [point(repository, "whole01", total: 20_000, shards: 4, at: 3.days.ago),
            point(repository, "infligh", total: 5_010, shards: 1, at: 2.days.ago),
            point(repository, "zeroooo", total: 0, shards: 4, at: 1.day.ago),
            point(repository, "whole02", total: 20_010, shards: 4, at: 1.hour.ago)]
    series = trajectory(runs)

    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      count += 1 unless payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])
    end
    series.plottable?
    series.coverage
    series.cohort_description
    series.withheld_count
    series.values
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(count).to eq(0)
    expect(series.plotted.map(&:commit_sha)).to eq(%w[whole01 whole02])
  end
end
