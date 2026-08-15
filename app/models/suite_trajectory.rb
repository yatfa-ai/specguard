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
  #
  # Named rather than spelled `2` at each site because the captions REPORT this threshold back to the
  # reader ("a trajectory needs 2"), and the sentence explaining why someone is being shown less than
  # they expected is the last place that should be able to disagree with the rule it is explaining.
  MINIMUM_POINTS = 2

  # Whether the suite-size line has the points to be a line at all.
  def plottable? = plotted.size >= MINIMUM_POINTS

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

  # == Why the withholding is one rule and two explanations
  #
  # The rule is symmetric: a run is withheld whenever its shard count differs from the cohort's, in
  # EITHER direction. The explanation that first suggests itself is not symmetric, and is true of
  # only one of them.
  #
  # "Its count is the sum of the shards reported so far, so it sits at a fraction of its own suite"
  # describes a run holding SOME of the cohort's parts and not all of them. Said about a run holding
  # MORE parts — or one that arrived whole in a single POST — it is false in every clause: during a
  # shard-layout migration those are the *more* completely assembled runs of the two, and a
  # repository whose CI just moved from four shards to eight would be told its complete new runs are
  # builds "still arriving". That is this panel's own defect aimed one layer out: an overclaim made
  # in the sentence that explains why the reader should not worry, rather than in the figure.
  #
  # So the direction is read off the data and each side gets the sentence that is true of it. Split
  # for the same reason `RepositoriesHelper#trajectory_withheld_reasons` refuses to total the two
  # withholding *reasons* into one number — a figure that merges two causes describes neither.

  # Withheld for holding some of the cohort's parts and not all of them: a build still arriving, or
  # a job cancelled part-way. The only group the fraction-of-its-own-suite sentence is true about.
  #
  # `positive?` and not merely `<`: zero shards is not "fewer parts", it is a run that arrived whole
  # (`TestRun#delivery_description`), which belongs below.
  def withheld_part_way
    @withheld_part_way ||= withheld_composition.select do |run|
      run.shard_count.positive? && run.shard_count < reference.shard_count
    end
  end

  # The rest: assembled from MORE parts than the cohort, or delivered whole where the cohort was
  # sharded. Not comparable with the line — and that is the whole claim. Nothing here says these
  # runs measured less than they should have, because as far as the data goes they may well have
  # measured more.
  def withheld_other_composition
    @withheld_other_composition ||= withheld_composition - withheld_part_way
  end

  # How a group of runs arrived, as one phrase, or `nil` when they did not all arrive the same way.
  # `TestRun#delivery_description` again, asked of a set: a mixed group has no single true phrase,
  # and the caption says nothing rather than picking one member's and generalising it.
  def shared_delivery_description(group)
    descriptions = Array(group).map(&:delivery_description).uniq
    descriptions.one? ? descriptions.first : nil
  end

  # Whether the newest run in the window is on the line.
  #
  # False in the state above — twenty four-shard runs and ten newer eight-shard ones puts the cohort
  # on the older layout, so the line stops before "now" while the Overview directly above names
  # today's SHA. Nothing about that is untrue, but "the latest run is on this line" is the one
  # inference a reader draws from a growth chart without being told, so the caption says it out loud
  # rather than leaving it to be inferred from two counts that happen not to match.
  def plots_newest? = plotted.last == runs.last

  def newest_run = runs.last

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

  # How the plotted runs arrived, in `TestRun#delivery_description`'s words and only in those —
  # the caption can then say what the line is a line THROUGH, and the mismatch sentence below it
  # can name the other side of the comparison in the same vocabulary.
  #
  # Routed rather than re-spelled. This method used to inflect "#{n} shard #{"report".pluralize(n)}"
  # itself, which is the third spelling of a rule this class's own doc argues against holding two
  # of: the day `delivery_description` changes "shard report" to "shard", the Overview and this
  # caption start describing the same run differently on the same page.
  #
  # And the carve-out that re-spelling forced — returning `nil` for the unsharded cohort, because
  # "the same 0 shard reports" would word a run that arrived whole as a delivery that lost
  # everything — dissolves with it. `delivery_description` already answers that case correctly, and
  # "all reported in one piece" is not noise: it is the clause the mismatch sentence contrasts
  # against when a sharded run is withheld from an unsharded line.
  def cohort_description = reference && "all #{cohort_delivery}"

  # The same phrase undressed, for a sentence that needs it mid-clause rather than as the basis
  # line's opening apposition. One source, two framings.
  def cohort_delivery = reference&.delivery_description

  def values = plotted.map { |run| run.total_specs_count.to_i }

  def minimum = values.min

  def maximum = values.max

  # Whether every plotted run measured the same suite. A real flat line, and a different statement
  # from the one `plottable?` refuses — this one was measured across comparable runs and says the
  # suite did not move.
  def flat? = minimum == maximum

  def first_run = plotted.first

  def last_run = plotted.last

  # == The same runs, read for what they cost rather than for what they contained
  #
  # Every row this class was handed already carries `duration_seconds`, so the runtime series below
  # is the plotted cohort read a second way — no second window, no second query, and deliberately
  # not a second panel.
  #
  # It rides on `plotted` and not on `runs` because a wall clock is only comparable within one
  # shard layout. `duration_seconds` on a run is the MAX over its shards (see `TestRun`), so a CI
  # config moving from four shards to eight halves the wall clock while nothing gets faster —
  # plotted naively that is a 2× speed-up wearing a real SHA. `plotted` has already withheld every
  # run not `assembled_like?` the cohort, and inheriting that is the argument for putting this
  # series here rather than anywhere else on the page.
  #
  # But it is only HALF the precondition a runtime line needs, and the half it is not was this
  # line's own defect. `assembled_like?` compares `shard_count` and nothing else, which is exactly
  # the question a SUM needs — `total_specs_count` is the sum over the shards recorded, so equal
  # counts is equal denominators. A MAX has a different denominator: `duration_seconds` is the
  # maximum over the shards that REPORTED, counted by `timed_shard_count`, and `assembled_like?`
  # never looks at it. Four timed shards (MAX 600s) against four shards whose two slowest were
  # cancelled (MAX 180s) is identical `shard_count`, identical `suite_size_measured?` — and a 70%
  # speed-up produced entirely by telemetry loss. The Overview panel on this same page refuses that
  # comparison for the scalar delta (`repositories/show.html.erb`, the `runtime_comparable` guard);
  # until the guard below, the chart drew it.
  #
  # What it does NOT inherit is timing coverage, in two separate shapes. `duration_seconds` is
  # nullable and `Ingest::Payload#validate_duration_seconds` accepts nil explicitly, so a run that
  # reported a suite and no clock is an ordinary state rather than a fault — and
  # `TestRun#duration_reported?` is deliberately `nil?` and not `present?`, because a measured `0.0`
  # is a measurement. Separately, a run that reported a clock may have reported it over fewer — or
  # more — shards than the rest of the line. Both come off this line and stay on the size line, and
  # both are carried rather than quietly dropped, in buckets of their own, the way
  # `withheld_part_way` and `withheld_other_composition` are carried above: a figure that merges two
  # causes describes neither.

  # The plotted runs that reported a wall clock at all — the candidates for the runtime line, before
  # the timing denominator is asked about. Not public: on its own it is the selection this class had
  # before the guard below, and nothing outside should be able to reach for it.
  private def clocked
    @clocked ||= plotted.select(&:duration_reported?)
  end

  # The plotted runs that reported a wall clock over the line's own timing denominator — the points
  # of the runtime line, oldest first.
  def timed
    @timed ||= if timing_reference
                 clocked.select { |run| run.timed_shard_count == timing_reference.timed_shard_count }
               else
                 []
               end
  end

  # Two points, for the reason `plottable?` wants two — and asked separately, because `plottable?`
  # does not imply it. A cohort of thirty runs of which one reported a clock is a plottable suite
  # size and not a trajectory of anything else.
  def runtime_plottable? = timed.size >= MINIMUM_POINTS

  # On the line for size, off it for time: reported no clock at all. Not a fault and not a zero —
  # the client sent nothing, so there is nothing to plot and nothing to infer from the absence.
  def withheld_untimed
    @withheld_untimed ||= plotted.reject(&:duration_reported?)
  end

  # On the line for size, off it for time for the OTHER reason: it reported a clock, over a
  # different number of shards than the line's points did. A distinct sentence from the one above,
  # because the causes are distinct — this run's client sent everything it was asked for, and some
  # of its shards did not report.
  #
  # Deliberately NOT worded "fewer", in either the name or the caption. The mismatch is symmetric:
  # a branch that consistently loses one shard's telemetry puts the timing cohort at three of four,
  # and it is then the fully-timed run that is withheld. Naming the bucket for one direction is the
  # overclaim `withheld_part_way`/`withheld_other_composition` were split apart to avoid, made in
  # the sentence that explains a withholding rather than in the figure.
  def withheld_timing_mismatch
    @withheld_timing_mismatch ||= clocked - timed
  end

  # The runtime series' own denominator, and its denominator is the PLOTTED cohort rather than the
  # window: the runs this line could have drawn through are the ones the size line drew through,
  # never the thirty the window held. Stating it against the window would count a shard-layout
  # mismatch as a timing gap, which is a different withholding with a different cause.
  #
  # Three sentences and not two, because there are now two ways to be off this line and a label that
  # said "3 of 4 plotted runs timed" over a run that DID time would be false in its own verb. The
  # arithmetic is the same in both shortfalls — the numerator is what got drawn — so the mismatch
  # case keeps it and qualifies what "timed" is being counted.
  def runtime_coverage
    return "every one of the #{plotted.size} plotted runs timed" if withheld_untimed.empty? &&
                                                                    withheld_timing_mismatch.empty?

    return "#{timed.size} of #{plotted.size} plotted runs timed" if withheld_timing_mismatch.empty?

    "#{timed.size} of #{plotted.size} plotted runs timed the same number of shards"
  end

  # Floats, unrounded and uncoerced. The chart scales to this series' own range, so the difference
  # between 74.25 and 74.80 is the whole picture; anything that flattens it here is a chart
  # asserting a suite whose runtime did not move.
  def runtime_values = timed.map { |run| run.duration_seconds.to_f }

  def runtime_minimum = runtime_values.min

  def runtime_maximum = runtime_values.max

  # Whether every timed run waited exactly as long — a real flat line, and about as likely as a
  # coincidence gets. Separate from `flat?`, which is a statement about the suite's SIZE: the two
  # answer independently and a panel that reused one for the other would say a suite that grew did
  # not.
  def runtime_flat? = runtime_minimum == runtime_maximum

  def first_timed_run = timed.first

  def last_timed_run = timed.last

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

  # The same rule again, on the other axis: a member of the largest cohort of runs that timed the
  # same number of shards, ties to the cohort holding the most recent one. `nil` when nothing on the
  # line reported a clock at all.
  #
  # Mirrored rather than hard-coded as `timed_shard_count == shard_count`, and the difference is the
  # whole point. A branch whose CI reliably loses one shard's telemetry reports three of four on
  # every run: those runs are perfectly comparable WITH EACH OTHER, and the strict rule would
  # withhold the entire line — which is precisely the failure the cohort rule above was written to
  # invert, arriving through a second door. What the line needs is one shared denominator, not a
  # full one.
  #
  # Safe on the unsharded corpus without a carve-out. A run with no shard rows has `shard_count` 0
  # and `timed_shard_count` 0 — `TestRun#preload_timed_shard_count` documents its `.to_i` for
  # exactly that, a really-counted zero and never a nil — so the equality holds trivially across
  # every run that named no `ci_run_id`, and the guard is a no-op there.
  #
  # Asked of `clocked` and not of `plotted`, because a run that sent no clock has a
  # `timed_shard_count` describing shards whose durations were never going to be plotted; letting it
  # vote would let runs that are not on this line pick this line's denominator.
  def timing_reference
    return @timing_reference if defined?(@timing_reference)

    @timing_reference = clocked.group_by(&:timed_shard_count)
                               .values
                               .max_by { |cohort| [cohort.size, clocked.index(cohort.last)] }
                               &.last
  end
end
