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
      # Worded through `TestRun#delivery_description`, which is why this is a sentence at all: the
      # phrase was once inflected here as "the same N shard reports", which for the unsharded
      # corpus means "the same 0 shard reports" — a run that arrived whole, described as a delivery
      # that lost everything. The one spelling in `TestRun` already answers this case, and the
      # answer is worth saying: it is the clause a withheld sharded run gets contrasted against.
      expect(series.cohort_description).to eq("all reported in one piece")
      expect(series.cohort_delivery).to eq("reported in one piece")
    end

    it "names the cohort's composition when there is one to name" do
      repository = create_repository
      runs = [point(repository, "whole01", total: 20_000, shards: 4, at: 2.days.ago),
              point(repository, "whole02", total: 20_010, shards: 4, at: 1.day.ago)]

      expect(trajectory(runs).cohort_description).to eq("all assembled from 4 shard reports")
    end

    # Inflection is `TestRun#delivery_description`'s to get right, and this asserts that the caption
    # is asking it rather than carrying a second copy of the rule that could drift from it.
    it "inflects a one-shard cohort rather than bolting an s on" do
      repository = create_repository
      runs = [point(repository, "single1", total: 1_000, shards: 1, at: 2.days.ago),
              point(repository, "single2", total: 1_010, shards: 1, at: 1.day.ago)]

      expect(trajectory(runs).cohort_description).to eq("all assembled from 1 shard report")
    end
  end

  # == The mismatch has two directions and only one of them is a fragment
  #
  # `assembled_like?` is symmetric, so a run is withheld whether it holds fewer parts than the
  # cohort or more. The in-flight/cancelled explanation is true only of the first. Told about the
  # second — a repository whose CI just moved from four shards to eight, or an unsharded corpus with
  # sharded CI runs arriving beside it — it says the MORE completely assembled runs are builds still
  # arriving, which is false in every clause.
  describe "which direction a withheld run missed the cohort in" do
    it "calls a run holding some of the cohort's parts part-way, and nothing else" do
      repository = create_repository
      runs = [point(repository, "whole01", total: 20_000, shards: 4, at: 3.days.ago),
              point(repository, "whole02", total: 20_010, shards: 4, at: 2.days.ago),
              point(repository, "infligh", total: 5_010, shards: 1, at: 1.minute.ago)]

      series = trajectory(runs)

      expect(series.withheld_part_way.map(&:commit_sha)).to eq(%w[infligh])
      expect(series.withheld_other_composition).to be_empty
    end

    # The reviewer's case, and the one the old fixed sentence was wrong about: eight COMPLETE
    # four-shard runs sitting beside a larger unsharded cohort. Every one of them measured its whole
    # suite across all four shards; none of them is a fraction of anything.
    it "does not call a complete sharded run a fragment when the cohort is unsharded" do
      repository = create_repository
      runs = 10.times.map { |i| point(repository, "plain0#{i}", total: 1_000 + i, at: (30 - i).days.ago) }
      runs += 3.times.map { |i| point(repository, "whole0#{i}", total: 20_000 + i, shards: 4, at: (5 - i).days.ago) }

      series = trajectory(runs)

      expect(series.plotted.size).to eq(10)
      expect(series.withheld_part_way).to be_empty
      expect(series.withheld_other_composition.map(&:commit_sha)).to eq(%w[whole00 whole01 whole02])
    end

    # Zero shards is not "fewer parts". A run that arrived whole in a single POST is not a partial
    # delivery of a four-shard one, and `TestRun#delivery_description` already refuses to word it as
    # a count of parts.
    it "does not call a whole delivery part-way merely for holding fewer shards than the cohort" do
      repository = create_repository
      runs = 3.times.map { |i| point(repository, "whole0#{i}", total: 20_000 + i, shards: 4, at: (5 - i).days.ago) }
      runs << point(repository, "laptop0", total: 12, at: 1.day.ago)

      series = trajectory(runs)

      expect(series.withheld_part_way).to be_empty
      expect(series.withheld_other_composition.map(&:commit_sha)).to eq(%w[laptop0])
    end

    it "separates the two directions when both are in the same window" do
      repository = create_repository
      runs = 3.times.map { |i| point(repository, "whole0#{i}", total: 20_000 + i, shards: 4, at: (9 - i).days.ago) }
      runs << point(repository, "infligh", total: 5_010, shards: 1, at: 3.days.ago)
      runs << point(repository, "newlyt0", total: 20_100, shards: 8, at: 2.days.ago)

      series = trajectory(runs)

      expect(series.withheld_part_way.map(&:commit_sha)).to eq(%w[infligh])
      expect(series.withheld_other_composition.map(&:commit_sha)).to eq(%w[newlyt0])
      # Still one figure between them, so the split cannot quietly lose or double-count a run.
      expect(series.withheld_count).to eq(2)
    end

    # A phrase for a group is only available when the group shares one. Generalising one member's
    # composition to a mixed set is the same overclaim in miniature.
    it "names a withheld group's composition only when they all arrived the same way" do
      repository = create_repository
      runs = 3.times.map { |i| point(repository, "plain0#{i}", total: 1_000 + i, at: (9 - i).days.ago) }
      alike = [point(repository, "whole01", total: 20_000, shards: 4, at: 3.days.ago),
               point(repository, "whole02", total: 20_010, shards: 4, at: 2.days.ago)]
      series = trajectory(runs + alike)

      expect(series.shared_delivery_description(series.withheld_other_composition))
        .to eq("assembled from 4 shard reports")

      mixed = trajectory(runs + alike + [point(repository, "eightsh", total: 20_020, shards: 8, at: 1.day.ago)])

      expect(mixed.shared_delivery_description(mixed.withheld_other_composition)).to be_nil
    end
  end

  # A growth chart's unstated premise is that its right-hand end is "now". During a shard-layout
  # migration it is not: the cohort is the older, larger group, so the newest runs are the withheld
  # ones and the line stops before the SHA the Overview names.
  describe "whether the newest run made it onto the line" do
    it "is true when the window's last run is the line's last point" do
      repository = create_repository
      runs = [point(repository, "aaaaaaa", total: 1_000, at: 2.days.ago),
              point(repository, "bbbbbbb", total: 1_047, at: 1.day.ago)]

      expect(trajectory(runs)).to be_plots_newest
    end

    it "is false when the most recent runs are the withheld ones" do
      repository = create_repository
      runs = 4.times.map { |i| point(repository, "oldwy0#{i}", total: 1_000 + i, shards: 4, at: (9 - i).days.ago) }
      runs += 2.times.map { |i| point(repository, "newwy0#{i}", total: 4_000 + i, shards: 8, at: (2 - i).days.ago) }

      series = trajectory(runs)

      expect(series.plotted.map(&:commit_sha)).to eq(%w[oldwy00 oldwy01 oldwy02 oldwy03])
      expect(series).not_to be_plots_newest
      expect(series.newest_run.commit_sha).to eq("newwy01")
    end

    # An unmeasured newest run counts too — it is withheld for a different reason, but the line
    # still does not reach it.
    it "is false when the newest run reported no tests" do
      repository = create_repository
      runs = [point(repository, "aaaaaaa", total: 1_000, at: 3.days.ago),
              point(repository, "bbbbbbb", total: 1_047, at: 2.days.ago),
              point(repository, "zeroooo", total: 0, at: 1.day.ago)]

      expect(trajectory(runs)).not_to be_plots_newest
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
    series.withheld_part_way
    series.withheld_other_composition
    series.shared_delivery_description(series.withheld_composition)
    series.plots_newest?
    series.values
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(count).to eq(0)
    expect(series.plotted.map(&:commit_sha)).to eq(%w[whole01 whole02])
  end
end
