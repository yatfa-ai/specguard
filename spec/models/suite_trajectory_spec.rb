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

    count = count_queries do
      series.plottable?
      series.coverage
      series.cohort_description
      series.withheld_count
      series.withheld_part_way
      series.withheld_other_composition
      series.shared_delivery_description(series.withheld_composition)
      series.plots_newest?
      series.values
    end

    expect(count).to eq(0)
    expect(series.plotted.map(&:commit_sha)).to eq(%w[whole01 whole02])
  end

  # The same rows read a second way: what these runs COST. Every figure below comes off columns the
  # window already loaded, and the series rides on `plotted` rather than on `runs` because a wall
  # clock is comparable only within one shard layout.
  describe "the wall-clock series" do
    def timed_point(repository, commit, total:, seconds:, shards: 0, at: 1.hour.ago)
      repository.test_runs.create!(commit_sha: commit, branch: "main", total_specs_count: total,
                                   duration_seconds: seconds, created_at: at)
                          .preload_shard_count(shards)
    end

    it "plots the wall clock of every plotted run that reported one" do
      repository = create_repository
      runs = [timed_point(repository, "aaaaaaa", total: 1_000, seconds: 40.2, at: 3.days.ago),
              timed_point(repository, "bbbbbbb", total: 1_020, seconds: 61.5, at: 2.days.ago),
              timed_point(repository, "ccccccc", total: 1_047, seconds: 74.25, at: 1.day.ago)]

      series = trajectory(runs)

      expect(series).to be_runtime_plottable
      expect(series.timed.map(&:commit_sha)).to eq(%w[aaaaaaa bbbbbbb ccccccc])
      expect(series.runtime_values).to eq([40.2, 61.5, 74.25])
      expect(series.runtime_minimum).to eq(40.2)
      expect(series.runtime_maximum).to eq(74.25)
      expect(series.withheld_untimed).to be_empty
      expect(series.runtime_coverage).to eq("every one of the 3 plotted runs timed")
    end

    # Nullable by design — `Ingest::Payload#validate_duration_seconds` accepts nil explicitly — so a
    # run that measured its suite and sent no clock is an ordinary state. It comes off THIS line and
    # stays on the size line, because the two withhold for different reasons.
    it "withholds a run that reported no timing while leaving it on the size line" do
      repository = create_repository
      runs = [timed_point(repository, "aaaaaaa", total: 1_000, seconds: 40.2, at: 3.days.ago),
              timed_point(repository, "silentc", total: 1_020, seconds: nil, at: 2.days.ago),
              timed_point(repository, "ccccccc", total: 1_047, seconds: 74.25, at: 1.day.ago)]

      series = trajectory(runs)

      expect(series.timed.map(&:commit_sha)).to eq(%w[aaaaaaa ccccccc])
      expect(series.withheld_untimed.map(&:commit_sha)).to eq(%w[silentc])
      expect(series.plotted.map(&:commit_sha)).to eq(%w[aaaaaaa silentc ccccccc])
      expect(series.runtime_coverage).to eq("2 of 3 plotted runs timed")
    end

    # A build that really did finish instantly measured something, and reporting it as an omission
    # would be reporting a measurement as an absence. The predicate this asks — `duration_reported?`
    # — is `nil?` for exactly that reason, and a `positive?`-shaped check in its place reads a
    # measured zero as nothing having been sent.
    it "keeps a run that measured 0.0 seconds, which is a measurement" do
      repository = create_repository
      runs = [timed_point(repository, "instant", total: 1_000, seconds: 0.0, at: 2.days.ago),
              timed_point(repository, "ccccccc", total: 1_047, seconds: 74.25, at: 1.day.ago)]

      series = trajectory(runs)

      expect(series.timed.map(&:commit_sha)).to eq(%w[instant ccccccc])
      expect(series.withheld_untimed).to be_empty
      expect(series.runtime_minimum).to eq(0.0)
    end

    # The whole reason this rides on `plotted`. `duration_seconds` is the MAX over a run's shards, so
    # four shards becoming eight halves the wall clock while nothing gets faster — a 2× speed-up
    # wearing a real SHA. The cohort rule the size line already enforces is exactly the guard this
    # line needs, and it is inherited rather than re-spelled.
    it "never plots a run assembled differently from the cohort, however well it was timed" do
      repository = create_repository
      runs = [timed_point(repository, "fourwid", total: 20_000, seconds: 74.25, shards: 4, at: 3.days.ago),
              timed_point(repository, "fourwi2", total: 20_010, seconds: 75.0, shards: 4, at: 2.days.ago),
              timed_point(repository, "eightwd", total: 20_020, seconds: 38.0, shards: 8, at: 1.day.ago)]

      series = trajectory(runs)

      expect(series.timed.map(&:commit_sha)).to eq(%w[fourwid fourwi2])
      expect(series.runtime_values).to eq([74.25, 75.0])
      # And the 38.0s run is not counted as a timing gap: it reported a clock, it is simply not
      # comparable. Wording it as untimed would name the wrong cause.
      expect(series.withheld_untimed).to be_empty
      expect(series.withheld_other_composition.map(&:commit_sha)).to eq(%w[eightwd])
    end

    # `plottable?` does not imply this one. Thirty comparable runs of which one reported a clock is
    # a plottable suite size and a trajectory of nothing else.
    it "refuses a line through a single timed run even when the size line is plottable" do
      repository = create_repository
      runs = [timed_point(repository, "aaaaaaa", total: 1_000, seconds: nil, at: 3.days.ago),
              timed_point(repository, "bbbbbbb", total: 1_020, seconds: nil, at: 2.days.ago),
              timed_point(repository, "ccccccc", total: 1_047, seconds: 74.25, at: 1.day.ago)]

      series = trajectory(runs)

      expect(series).to be_plottable
      expect(series).not_to be_runtime_plottable
      expect(series.timed.map(&:commit_sha)).to eq(%w[ccccccc])
    end

    # Two independent questions about the same cohort. A suite that grew while its wall clock held
    # steady is the ordinary case, and a panel that answered one out of the other would say the
    # suite did not move.
    it "answers flatness separately for size and for runtime" do
      repository = create_repository
      runs = [timed_point(repository, "aaaaaaa", total: 1_000, seconds: 74.25, at: 2.days.ago),
              timed_point(repository, "bbbbbbb", total: 1_047, seconds: 74.25, at: 1.day.ago)]

      series = trajectory(runs)

      expect(series).not_to be_flat
      expect(series).to be_runtime_flat
    end

    # Floats, uncoerced. 74.25 → 74.80 is a real 0.55s regression, and an integer coercion anywhere
    # on this path renders it as a flat line — the one shape that asserts the wait did not move.
    it "keeps a sub-second range rather than coercing it away" do
      repository = create_repository
      runs = [timed_point(repository, "aaaaaaa", total: 1_000, seconds: 74.25, at: 2.days.ago),
              timed_point(repository, "bbbbbbb", total: 1_047, seconds: 74.80, at: 1.day.ago)]

      series = trajectory(runs)

      expect(series.runtime_values).to eq([74.25, 74.80])
      expect(series).not_to be_runtime_flat
    end

    it "asks the database nothing for any of it" do
      repository = create_repository
      runs = [timed_point(repository, "aaaaaaa", total: 1_000, seconds: 40.2, at: 3.days.ago),
              timed_point(repository, "silentc", total: 1_020, seconds: nil, at: 2.days.ago),
              timed_point(repository, "ccccccc", total: 1_047, seconds: 74.25, at: 1.day.ago)]
      series = trajectory(runs)

      count = count_queries do
        series.runtime_plottable?
        series.runtime_coverage
        series.runtime_values
        series.runtime_minimum
        series.runtime_maximum
        series.runtime_flat?
        series.withheld_untimed
        series.first_timed_run
        series.last_timed_run
      end

      expect(count).to eq(0)
    end
  end
end
