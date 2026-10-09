# frozen_string_literal: true

# THE PER-SHARD DECOMPOSITION READERS OF `TestRun`, MOVED OUT WHOLE — `#shard_durations` and every
# public reader derived from it (`#shard_reports`, the wall-clock excess family, the shard
# distribution labels, the spec-count / seconds-per-spec spread family), plus the four private
# formatting helpers only they use. `TestRun` `include`s this module, so every caller keeps
# spelling them `test_run.<method>` and the receiver is still the model instance (`test_run_shards`,
# `duration_seconds`, `machine_seconds`, `shard_count` and the private `humanized_seconds` resolve
# as before).
#
# MOVE ONLY. Every method body and comment below is byte-identical to what it was in
# `app/models/test_run.rb`, apart from the extra indentation of the module nesting. The comments
# still say "above", "below" and "this slice", and those coordinates are RELATIVE TO THE OLD
# FILE — they were not rewritten, so read a position word as pointing into `TestRun`, not into
# this module.
#
# THE CONSTANTS AND THE GATE PREDICATES STAY ON `TestRun`. This module is nested lexically inside
# the class, so the unqualified `NEGLIGIBLE_EXCESS_SECONDS`, `NEGLIGIBLE_EXCESS_PERCENT` and
# `NEGLIGIBLE_SPREAD_PERCENT` resolve exactly as they did. `#wall_clock_decomposable?`,
# `#wall_clock_decomposition_pending?`, `#shard_delivery_settled?`, the counts seams and the
# private `#shard_totals` / `#humanized_seconds` are not part of this family.
class TestRun < ApplicationRecord
  module ShardDecomposition
    # Every shard's `[shard_id, duration_seconds, total_specs_count]`, slowest first.
    #
    # ONE query for all of them regardless of how many there are — a 40-shard matrix costs the same
    # as a 4-shard one. It is a second read against `test_run_shards` beside the memoized
    # `shard_totals` aggregate, which is deliberate: `shard_totals` is a `pick` of three scalars and
    # feeds `GET /api/v1/repository`, so widening it to carry rows would change what its callers
    # load for a figure only the dashboard renders. Constant, not minimal, is the property that
    # matters.
    #
    # `total_specs_count` rides along rather than taking a read of its own, and the position it rides
    # in is load-bearing in exactly the way `MAX(updated_at)` is on `#shard_totals`: it is APPENDED,
    # so index 0 stays `shard_id` and index 1 stays `duration_seconds`, and `#longest_shard_label`'s
    # `shard_durations.first&.first` keeps naming a shard rather than a count. A wider `pluck` over
    # the same index is the same round trip.
    #
    # It is the denominator of every duration beside it, and without it the distribution below cannot
    # separate the two things a slow shard can be: a shard holding more tests than its siblings — the
    # split is wrong — from a shard holding the same number of individually dearer ones, where the
    # split is fine and the tests are where the cost is. Both print byte-identically on durations
    # alone. `Ingest::RunRecorder#upsert_shard` has written this column on every sharded POST since
    # sharding shipped; nothing read it.
    #
    # Ordered by duration rather than by `shard_id` or by insertion, because the point of rendering
    # the list at all is to make the *shape* visible: slowest-first puts the shard just named at the
    # head and walks down to the fastest, so the spread reads off in one pass. Ordering by name
    # would sort `"10"` before `"2"` (the column is a string, and it is a string because a client
    # may name its slices anything), and ordering by insertion would sort by whichever shard
    # happened to POST first, which is not a fact about the suite. `id` breaks ties so the order is
    # total and stable.
    #
    # **Safe only behind `#wall_clock_decomposable?`, and that is load-bearing rather than
    # incidental** — the same kind of fact `#some_shard_untimed?` records about its own vacuous
    # false. `duration_seconds: :desc` is **NULLS FIRST** in Postgres, so on a run carrying a silent
    # shard the head of this list is the shard that reported *nothing*, and `#longest_shard_label`
    # below would name it as the longest while `#shard_distribution_labels` printed it at the top of
    # the distribution. Unreachable today because the gate's `!some_shard_untimed?` condition is
    # exactly the statement that no such row exists — but this method and EVERY public reader derived
    # from it below re-check nothing, so a future caller that skipped the gate would be handed an
    # untimed row wearing the word "longest". Call any of them from anywhere else and either keep the
    # gate or order `NULLS LAST` first.
    #
    # That enumeration is stated as a rule and not as a count on purpose. It read "all three of these
    # readers" until this slice, which was true when it was written and false the moment
    # `#shard_spec_counts` and `#shard_seconds_per_spec` were added below — the one paragraph that
    # bounds the ungated exposure understating it by two, in the commit that widened it. A rule the
    # next reader has to satisfy cannot rot the way a tally does.
    def shard_durations
      @shard_durations ||= test_run_shards.order(duration_seconds: :desc, id: :asc)
                                          .pluck(:shard_id, :duration_seconds, :total_specs_count)
    end

    # The same three columns in DELIVERY order, for a machine-readable consumer.
    #
    # A separate read rather than a reuse of `#shard_durations`, because the ORDER is the whole
    # difference between them and the order is what decides where each is safe. `#shard_durations`
    # RANKS by duration, which is NULLS FIRST in Postgres, so it is safe only behind
    # `#wall_clock_decomposable?` — whose `!some_shard_untimed?` condition is precisely the statement
    # that no untimed row exists to surface at the head. `GET /api/v1/repository`'s `shards` block
    # gates on `#multi_shard?` alone, which establishes nothing of the kind, and widening the tuple
    # is not a licence to call a ranked list from an unranked gate.
    #
    # So this ranks nothing: `id: :asc` is the order the shards were recorded in, a fact about the
    # deliveries rather than a claim about the suite, and a client that wants them slowest-first
    # sorts them itself over a `duration_seconds` it can see is null. One query, constant in the
    # number of shards, on `index_test_run_shards_on_test_run_id`.
    def shard_reports
      @shard_reports ||= test_run_shards.order(id: :asc)
                                        .pluck(:shard_id, :duration_seconds, :total_specs_count)
    end

    # What to call one shard in a sentence.
    #
    # `shard_id` is nullable and a nil one is not an oversight — `Ingest::RunRecorder#upsert_shard`
    # says outright that a client which shards without exposing an index the gem recognises sends
    # nothing to tell its slices apart, so each POST becomes its own row. Numbering those rows by
    # their position in this list would hand a reader a name the client never sent, and a stable-
    # looking one: "shard 2 is your slow shard" is unactionable advice when nothing in CI is called
    # shard 2, and it would point at a different slice on the next run.
    #
    # One label and not two — the same string names a shard in the prose and in the list below it,
    # so the sentence and the row a reader checks it against cannot drift apart.
    def shard_label(shard_id) = shard_id.present? ? "shard #{shard_id}" : "an unnamed shard"

    # The name of the shard the run's `duration_seconds` MAX came from.
    #
    # Named for the measurement and not for the verdict. Being the longest is a fact about the row;
    # being *the slowest* is a claim about the run, and the panel deliberately declines to make it
    # when four shards are tied to the tenth. A method called `slowest_shard_label` feeding a
    # sentence that refuses the word "slowest" is a name working against its own caller — the same
    # discipline `#wall_clock_coverage` applies one section up, where the label is allowed to say
    # "slowest of 4 shards" only in the branch where the MAX covers all four.
    #
    # Reads the head of `#shard_durations`, so it inherits that method's NULLS-FIRST dependency on
    # the gate verbatim: off-gate, on a run with a silent shard, this names the shard that reported
    # nothing.
    def longest_shard_label = shard_label(shard_durations.first&.first)

    # The shortest wall clock any arrangement of these shards could have produced: the machine time
    # spread perfectly evenly across them.
    #
    # A **lower bound and never a target**. Tests are not arbitrarily divisible — a single example
    # longer than this floor makes it unreachable on its own — so nothing here claims such a split
    # exists, only that none can go under it. Every surface rendering this has to word it that way.
    def balanced_wall_clock_seconds = machine_seconds / shard_count

    # How much longer the run waited than that floor: the part of the wait attributable to how the
    # suite was divided rather than to the suite itself.
    #
    # Unguarded on `duration_seconds` where `#duration_label` guards the same column with
    # `#duration_reported?`, and the reason is written here because it is the one link in the chain
    # that is not visible from this file. `Ingest::RunRecorder#recompute_totals` re-derives the
    # parent's `duration_seconds` as the MAX over its shard rows after every ingest, and a MAX over
    # rows that all reported a timing cannot be NULL — which is exactly what the gate's
    # `!some_shard_untimed?` condition establishes. So the invariant holds through the recorder and
    # nowhere else: call this outside `#wall_clock_decomposable?` and it raises on a nil.
    def wall_clock_excess_seconds = duration_seconds - balanced_wall_clock_seconds

    # The same as a share of the wait.
    #
    # Guarded on a positive denominator, not on a blank one: a run whose shards all genuinely
    # measured `0.0` is a real state with a real (zero) excess, and `0.0 / 0.0` is `NaN` — which
    # formats as `NaN%` and compares false against every threshold, so it would slip past the
    # materiality test below and render as a finding.
    def wall_clock_excess_percent
      return 0.0 unless duration_seconds.to_f.positive?

      (wall_clock_excess_seconds / duration_seconds * 100).round(1)
    end

    # Whether that excess is worth reading as a finding rather than as noise.
    #
    # This decides the WORDING and never whether the number is shown. An evenly split run has a
    # measured excess of `0.0s` and says so; what it does not do is dress that up as time something
    # could have recovered. Same rule the machine time follows one section up — an incomplete fact
    # carries its incompleteness in the words, and an unremarkable one carries that.
    #
    # Both operands are compared at the precision they are RENDERED at, which is why the seconds are
    # rounded here even though nothing stores them rounded. The percent has always been thresholded
    # on the value the reader sees (`#wall_clock_excess_percent` rounds), and the seconds reach the
    # page through `humanized_seconds`, which rounds to the same tenth. Judging one operand rounded
    # and the other raw opens a seam either side of the boundary where two runs print the identical
    # figure and receive opposite verdicts — `[17.0, 18.96]` and `[17.0, 19.04]` both read `1.0s`
    # over the floor — which is this ticket's own defect one level down. The boundary belongs where
    # a reader can see it.
    def wall_clock_excess_material?
      wall_clock_excess_seconds.round(1) >= NEGLIGIBLE_EXCESS_SECONDS &&
        wall_clock_excess_percent >= NEGLIGIBLE_EXCESS_PERCENT
    end

    # The floor and the excess, formatted by the same formatter the wall clock and the machine time
    # already use. Four numbers in one unit within a few lines of each other: a second formatter
    # would eventually print them two ways and destroy the comparison they exist to enable.
    #
    # A known and accepted consequence: at a minute and above `humanized_seconds` drops the tenth, so
    # the three figures do not reconcile by subtraction on screen. The canonical run prints a `1m 14s`
    # wait and a `1m 3s` floor, and a reader taking the difference gets `11s` where the excess reads
    # `10.8s`. The alternative is a second formatter for the excess alone — which would print the
    # wait and the floor at one precision and the gap between them at another, in a paragraph whose
    # entire purpose is to relate the three. A rounding seam is the smaller cost, and it is only ever
    # a tenth wide.
    def balanced_wall_clock_label = humanized_seconds(balanced_wall_clock_seconds)
    def wall_clock_excess_label = humanized_seconds(wall_clock_excess_seconds)

    # Every shard as `[name, formatted duration, size, per-test cost]`, slowest first — the
    # distribution itself, so the shape is visible rather than summarised into a single ratio.
    # Formatted here rather than in the view for the reason directly above: `humanized_seconds` is
    # private, and it stays private.
    #
    # Named for the distribution rather than for the durations it used to be, because it is no longer
    # a list of durations: the size and the cost per test are the two figures that say whether a long
    # shard is long because it holds more work or because its work is dearer, and a method still
    # called `shard_duration_labels` would be a name arguing against its own contents.
    #
    # The fourth element is `nil` — never a formatted zero — for a shard with no denominator, and the
    # third states that absence in words. See `#shard_size_label`.
    #
    # Zipped against `#shard_seconds_per_spec` rather than re-derived per row, so *which shards have
    # a cost per test* is decided in exactly one place. An earlier draft called a private
    # `#shard_seconds_per_spec_label` that repeated the `seconds.nil? || !spec_count.to_i.positive?`
    # test, which put the same load-bearing predicate behind two surfaces — this list and the spread
    # comparison — free to drift apart into a row showing a rate for a shard the spread excluded,
    # with each half independently green. The alignment `#shard_seconds_per_spec` promises (nils kept
    # in place, not compacted) is what makes the zip safe, and this is the caller it was promised to.
    def shard_distribution_labels
      shard_durations.zip(shard_seconds_per_spec).map do |(shard_id, seconds, spec_count), rate|
        [shard_label(shard_id), humanized_seconds(seconds), shard_size_label(spec_count),
         rate && humanized_seconds_per_spec(rate)]
      end
    end

    # == Which of the two things a slow shard is
    #
    # The section above measures the spread of the shards' WALL CLOCKS and says how much of the wait
    # it cost. It cannot say what caused it, and the two causes take opposite actions:
    #
    # - the slow shard holds more tests than its siblings — the work is fine, the *split* is wrong,
    #   and evening the counts out across the same shards is what moves the number;
    # - the slow shard holds the same number of individually dearer tests — the counts are already
    #   even, so a partitioner splitting by COUNT has nothing left to even out and reproduces the gap
    #   however often it re-runs. A duration-weighted split, or cheaper tests in that partition, is
    #   what moves it.
    #
    # Note what is NOT different between the two, because an earlier draft of these strings got it
    # wrong and shipped operational advice this model's own arithmetic falsifies: machine time is
    # invariant under re-partitioning and the balanced floor is `machine / shard_count`
    # (`#balanced_wall_clock_seconds`), so a duration-weighted split reaches the floor in BOTH cases
    # and `#wall_clock_excess_seconds` is recoverable in BOTH. What the count spread decides is which
    # partitioner can get there — never whether re-dividing helps at all. Any string built from these
    # names a partitioner; none of them may tell a reader the excess is unrecoverable.
    #
    # `duration = count × cost-per-test`, so the two are separately computable from the tuple
    # `#shard_durations` now carries, and the panel is entitled to name whichever of them the numbers
    # support — including neither, when a material duration spread is the product of two immaterial
    # ones. Same discipline `#wall_clock_coverage` and `#longest_shard_label` apply: the branch that
    # cannot carry a word does not say it.
    #
    # **A shard is not a code area.** RSpec/Knapsack partitions are arbitrary with respect to
    # directory structure, so "which partition of this run is expensive per test" is the question
    # answered here. "Which DIRECTORY is expensive" is a different question with a different answer,
    # and it is answered elsewhere — `SpecObservation.directory_durations_in` rolls the same run's
    # per-example rows up by code area. The two are not substitutes and cannot be read off each
    # other: an area's cost is spread across every shard that happened to draw its files. Every
    # string built from these has to be worded so a reader cannot mistake one for the other.

    # Each shard's test count, in `#shard_durations` order. `.to_i` because the column is
    # `null: false, default: 0` — a shard that loaded no specs is a real row carrying a real zero.
    def shard_spec_counts = shard_durations.map { |_shard_id, _seconds, spec_count| spec_count.to_i }

    # Each shard's seconds per test, in the same order, with `nil` for any shard that has no
    # denominator to divide by (or no numerator to divide). Aligned with `#shard_durations` rather
    # than compacted, so a caller cannot line a rate up against the wrong shard.
    #
    # **Two different absences arrive here as the same `nil`, and they are not the same fact.** A
    # shard with `total_specs_count = 0` reported a wall clock over no tests — an ordinary row, since
    # the column is `null: false, default: 0`, and the one `#unsized_shard_count` counts. A shard
    # with a null `duration_seconds` reported no wall clock at all, which is the coverage gap
    # `#some_shard_untimed?` / `#untimed_shard_count` already word for the whole panel. Collapsing
    # them here is correct for THIS list — neither shard has a cost per test, and this list is of
    # costs per test — but it means `nil` here answers "is there a rate?" and never "why not". A
    # caller that wants to SAY why must ask one of those two named predicates; it cannot recover the
    # reason from this array.
    def shard_seconds_per_spec
      @shard_seconds_per_spec ||= shard_durations.map do |_shard_id, seconds, spec_count|
        next nil if seconds.nil? || !spec_count.to_i.positive?

        seconds / spec_count
      end
    end

    # How many shards reported no tests at all. Not an error state: `total_specs_count` defaults to
    # `0` and a client can deliver a slice that loaded nothing.
    def unsized_shard_count = shard_spec_counts.count(&:zero?)

    # Whether every shard has a per-test cost. False makes the cost comparison below unavailable
    # rather than approximate — the line `#suite_size_measured?` draws for the run-level column, one
    # level down: a shard with a duration and no denominator has a wall clock and no cost per test,
    # and dividing by its zero, or quietly taking the spread over the rest and calling it the run's,
    # are both figures this panel cannot stand behind.
    #
    # **Named for the conjunction it is, not for either half.** It is false in two distinct states —
    # a shard that reported no TESTS and a shard that reported no TIMING — because
    # `#shard_seconds_per_spec` needs both and its comment writes out why the two nils differ. An
    # earlier draft of this called itself `every_shard_sized?`, which named only the first half while
    # answering both, and the sentence built on it then reported `#unsized_shard_count` — a count of
    # the first half alone — as the evidence for a branch the second half could also have entered.
    # Anything that wants to SAY which absence it hit branches on `#unsized_shard_count` or on
    # `#untimed_shard_count`, the two predicates that each name one of them; this one is for deciding
    # whether a cost figure exists at all.
    #
    # Vacuously TRUE on a run with no shards (`[].none?`), which is safe only because every caller
    # sits behind `#wall_clock_decomposable?` — the same load-bearing vacuity `#some_shard_untimed?`
    # records about its own vacuous false, and it fails the same way: a future ungated caller would
    # read "every shard has a cost" off a run that has no shards. That same gate is also what makes
    # the untimed half of this predicate unreachable from the panel today: `!some_shard_untimed?` is
    # exactly the statement that no null-duration row is present.
    def every_shard_costed? = shard_seconds_per_spec.none?(&:nil?)

    # How far apart the shards' test counts are, as a percentage of their mean. `nil` when there is
    # no mean to divide by — every shard reported zero — which is a real state and not a spread of 0.
    def spec_count_spread_percent = relative_spread_percent(shard_spec_counts)

    # The same dispersion over the per-test costs, and `nil` unless every shard has one. A spread
    # taken over the sized shards alone would be a fact about a subset wearing a sentence about the
    # run.
    def seconds_per_spec_spread_percent
      return nil unless every_shard_costed?

      relative_spread_percent(shard_seconds_per_spec)
    end

    # Whether each spread is worth reading as a cause rather than as noise. Both decide WORDING and
    # never whether a number is shown — the rule `#wall_clock_excess_material?` states. A `nil`
    # spread is not material: an uncomputable figure is not a finding.
    def spec_count_spread_material?
      spec_count_spread_percent.present? && spec_count_spread_percent >= NEGLIGIBLE_SPREAD_PERCENT
    end

    def seconds_per_spec_spread_material?
      seconds_per_spec_spread_percent.present? &&
        seconds_per_spec_spread_percent >= NEGLIGIBLE_SPREAD_PERCENT
    end

    # The two spreads as strings, rounded where they are compared and formatted where they are read —
    # `#relative_spread_percent` rounds to the tenth and the thresholds above are applied to that
    # rounded value, so the boundary a reader can see is the boundary the branch was chosen on. This
    # is `#wall_clock_excess_material?`'s rule about judging an operand at the precision it renders.
    def spec_count_spread_label = "#{spec_count_spread_percent}%"
    def seconds_per_spec_spread_label = "#{seconds_per_spec_spread_percent}%"

    # The cheapest and dearest per-test costs on record, for a sentence that wants the two ends of
    # the spread rather than the spread itself. `nil` unless every shard has a cost, on
    # `#every_shard_costed?`'s rule.
    def cheapest_seconds_per_spec_label = extreme_seconds_per_spec_label(:min)
    def dearest_seconds_per_spec_label = extreme_seconds_per_spec_label(:max)

    private

    # How far apart a set of per-shard values is, as a percentage of their own mean.
    #
    # `(max - min) / mean` and not `max / min`: a ratio against the smallest is undefined the moment
    # one shard reports zero — the ordinary state this section has to survive — and it explodes
    # rather than degrading as the smallest approaches it. Dividing by the mean keeps the figure
    # finite over any set with a positive mean, and reads as "how wide, relative to typical", which
    # is the sentence the panel wants.
    #
    # `nil`, never `0.0`, when there is no mean to divide by. A set that is entirely zeroes has no
    # dispersion *to measure*, and reporting that as a measured 0% would let "the shards are evenly
    # sized" be said about shards that reported nothing at all.
    #
    # Rounded to the tenth because that is the precision this figure is RENDERED at, and the
    # materiality thresholds are applied to the value this returns — so two runs printing the same
    # percentage cannot receive opposite verdicts. `#wall_clock_excess_material?` writes out why.
    def relative_spread_percent(values)
      return nil if values.empty?

      mean = values.sum.to_f / values.length
      return nil unless mean.positive?

      ((values.max - values.min) / mean * 100).round(1)
    end

    # One shard's size, or the stated absence for a shard that loaded none.
    #
    # `total_specs_count` is `null: false, default: 0`, so "no tests" is a real row and not a missing
    # one — and it is the row with a wall clock and no denominator. It renders as words rather than
    # as `0 tests` beside a `0.0ms/test`, because a computed zero there would read as "these tests
    # are free" about a shard that ran no tests at all.
    def shard_size_label(spec_count)
      count = spec_count.to_i
      return "no tests reported" unless count.positive?

      "#{ActiveSupport::NumberHelper.number_to_delimited(count)} #{"test".pluralize(count)}"
    end

    # A per-test cost, in the unit that keeps it legible.
    #
    # NOT `humanized_seconds`, which is right for the three run-level figures that sit within a few
    # lines of each other and wrong here: this quantity is three to five orders of magnitude smaller,
    # and `74.25 / 5000` through that formatter prints `0.0s` — a computed zero, in the panel whose
    # rule is that a figure it cannot stand behind is withheld with its reason rather than rounded
    # away. A different unit is not a second formatter for the same quantity; it is the first
    # formatter for a different one, and it says its unit on every value so the two cannot be
    # confused for each other on the same line.
    #
    # Three branches because there are three magnitudes a real suite produces: a slow integration
    # suite at seconds per example, an ordinary unit suite at milliseconds, and a suite so fast the
    # tenth of a millisecond stops resolving it. The last states a bound rather than rounding to
    # `0.0ms/test`, on the same rule as `#shard_size_label`.
    def humanized_seconds_per_spec(value)
      return "#{value.round(1)}s/test" if value >= 1.0

      millis = value * 1000
      return "#{millis.round(1)}ms/test" if millis.round(1).positive?

      "under 0.1ms/test"
    end

    # The cheapest or dearest per-test cost, formatted. `nil` unless every shard has one, so a
    # sentence naming the two ends of the spread cannot quote an end of a subset.
    def extreme_seconds_per_spec_label(bound)
      return nil unless every_shard_costed?

      humanized_seconds_per_spec(shard_seconds_per_spec.public_send(bound))
    end
  end
end
