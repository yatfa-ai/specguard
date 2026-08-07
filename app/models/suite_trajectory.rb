# frozen_string_literal: true

# Which runs in a branch's history may be drawn as one line, and what the line therefore covers.
#
# Handed the rows `Repository#suite_size_trajectory` loaded, this decides which of them are points
# and which are withheld, and carries the vocabulary the caption states that with. It stores no
# figure of its own: every number it reports is counted off the runs it was given.
#
# == Why anything is withheld at all
#
# `TestRun#total_specs_count` is not a suite size. On a run with shards it is the SUM over the
# shards recorded SO FAR — `Ingest::RunRecorder#recompute_totals` re-derives it after every ingest
# — so a four-shard 20,000-example suite reads as ~5,000 for most of its own build, and a job
# cancelled after two of four shards leaves a half-sized row in the history permanently. A *level*
# survives that. A *line between two levels* does not: plotted naively, every one of those rows is
# a cliff to a quarter of the suite and back, a mass test deletion rendered as a fact and wearing a
# real SHA.
#
# The Overview panel already refuses that subtraction across two runs, through
# `TestRun#suite_size_measured?` and `#assembled_like?`. This is the same two questions asked of
# thirty rows instead of two, through the same two predicates — deliberately not a third spelling
# of the rule, because two spellings is how the chart and the Overview would eventually disagree
# about whether the same run measured a suite.
#
# == What "the same kind of measurement" means across many runs
#
# `assembled_like?` is pairwise, and a series has no single pair. The reference is the largest
# COHORT — the biggest group of runs in the window that were all assembled the same way — with
# ties going to the cohort holding the most recent run.
#
# Largest rather than "like the latest run", which is the reading that first suggests itself and is
# wrong in exactly the state this class exists for: while a four-shard build is in flight the latest
# run is a one-shard row, and anchoring on it would withhold the twelve complete runs and plot the
# fragments. The cohort rule inverts correctly there — the fragment is a cohort of one and loses.
class SuiteTrajectory
  # `runs` oldest-first, each already primed with its shard count (see
  # `Repository#suite_size_trajectory`). `branch` is passed rather than read off the runs so an
  # empty series can still name the branch it found nothing on.
  def initialize(runs:, branch:)
    @runs = Array(runs)
    @branch = branch
  end

  attr_reader :runs, :branch

  # Runs that measured a suite AND were assembled like the dominant cohort — the points of the
  # line, oldest first.
  def plotted
    @plotted ||= reference ? measured.select { |run| run.assembled_like?(reference) } : []
  end

  # Two points, because one point is not a trajectory and drawing it as a line would be drawing a
  # flat one — the single shape that asserts a stable suite while measuring nothing of the sort.
  def plottable? = plotted.size >= 2

  # Reported a count but not a measurement. Withheld for the reason the Overview withholds its
  # delta against one: a zero here describes the report, not the suite.
  def withheld_unmeasured
    @withheld_unmeasured ||= runs.reject(&:suite_size_measured?)
  end

  # Measured a suite, but not the same way the cohort did — the in-flight window, the cancelled
  # job, a laptop run sitting among sharded CI ones.
  def withheld_composition
    @withheld_composition ||= measured - plotted
  end

  def withheld_count = withheld_unmeasured.size + withheld_composition.size

  def considered_count = runs.size

  # The series' own denominator, carried by the label rather than left to a caveat further down the
  # page — the rule `TestRun#machine_seconds_coverage` states and the reason it states it: a label
  # is the most prominent claim a figure wears, and "15 runs" over a line through 12 of them is the
  # same overclaim whatever the caption says afterwards. Only the complete case says "every".
  def coverage
    return "#{plotted.size} of #{considered_count} runs plotted" if withheld_count.positive?

    "every one of the last #{considered_count} runs plotted"
  end

  # How the plotted runs were assembled, as a phrase — `TestRun#delivery_description` asked of the
  # cohort rather than of one row, so the caption can say what the line is a line THROUGH.
  # `nil` for the unsharded corpus, which has no composition to state: "the same 0 shard reports"
  # would describe a run that arrived whole as a delivery that lost everything.
  def cohort_description
    return nil if reference.nil? || reference.shard_count.zero?

    "assembled from the same #{reference.shard_count} shard #{"report".pluralize(reference.shard_count)}"
  end

  def values = plotted.map { |run| run.total_specs_count.to_i }

  def minimum = values.min

  def maximum = values.max

  # Whether every plotted run measured the same suite. A real flat line, and a different statement
  # from the one `plottable?` refuses — this one was measured across comparable runs and says the
  # suite did not move.
  def flat? = minimum == maximum

  def first_run = plotted.first

  def last_run = plotted.last

  private

  def measured
    @measured ||= runs.select(&:suite_size_measured?)
  end

  # A member of the largest same-composition cohort — any member would do, since `assembled_like?`
  # reads only the shard count, but the newest is the one worth naming. `nil` when nothing in the
  # window measured a suite at all.
  #
  # `group_by` preserves arrival order inside each group, so `cohort.last` is that cohort's newest
  # run and `measured.index` of it is how recently the cohort was last seen — the tie-break.
  def reference
    return @reference if defined?(@reference)

    @reference = measured.group_by(&:shard_count)
                         .values
                         .max_by { |cohort| [cohort.size, measured.index(cohort.last)] }
                         &.last
  end
end
