# frozen_string_literal: true

# THE RUN-GRAIN HISTORY/LAYER READS OF `SpecObservation`, MOVED OUT WHOLE — the ten class methods
# that answer a run's declared-layer questions and the one aggregate row they all share:
# `layer_counts_in`, `run_layer_counts_for`, `run_layer_counts_and_durations_for`,
# `run_layer_count_expressions`, `run_layer_duration_expressions`, `run_layer_count_offset`,
# `run_layer_seconds_offset`, `run_layer_timed_offset`, `layer_durations_in` and `run_counts_in`.
# `SpecObservation` `extend`s this module, so every caller keeps spelling them
# `SpecObservation.<method>` and the receiver is still the model class (`where` and the constants
# resolve as before).
#
# MOVE ONLY. Every method body and comment below is byte-identical to what it was in
# `app/models/spec_observation.rb`; the sole code edit is `def self.x` -> `def x` (plus the extra
# indent), and the emitted SQL did not change. The comments still say "above", "below" and `{.foo}`,
# and those coordinates are RELATIVE TO THE OLD FILE — they were not rewritten, so read a position
# word as pointing into `SpecObservation`, not into this module. (A bare "this file" in the moved
# prose likewise names `app/models/spec_observation.rb`.)
#
# THE CONSTANTS STAY ON `SpecObservation`. This module is nested lexically inside the class, so the
# unqualified `RUN_READING_COUNTS`, `DECLARED_LAYER_KEYS` and the `IntentReadings` class resolve
# exactly as they did, and a `stub_const("SpecObservation::...")` in a spec still bites because the
# lookup happens at call time. `directory_layer_count_expressions` and `declared_layer_predicates`
# stay on the model too — the shared builders `RunReads`' header keeps there ("the history family
# and the shared builders need them too") — and are reached through the same receiver.
class SpecObservation < ApplicationRecord
  module HistoryReads
    # The RUN-grain declared-layer mix — how many of the run's recorded examples DECLARED each layer in
    # their `@intent`, plus how many declared none: `{unit:, integration:, request:, system:,
    # undeclared:}` in {DECLARED_LAYER_KEYS} order, a measured zero where nothing declared that layer
    # (never nil), summing to `IntentReadings#recorded`. NIL for a run with no recorded per-example rows:
    # a run that stored no detail has no mix to state, and five zeros would read as a measurement of an
    # empty suite. Operands only, no verdict — and the path is never consulted (see
    # {.directory_layer_count_expressions}).
    #
    # The SAME aggregate row as {.reading_counts_in}, not a second read: see {.run_counts_in}.
    def layer_counts_in(test_run)
      run_counts_in(test_run)[1]
    end

    # The RUN-grain declared-layer mix for MANY runs in ONE grouped read — `{run_id => {unit:,
    # integration:, request:, system:, undeclared:}}` in {DECLARED_LAYER_KEYS} order, each value
    # exactly what {.layer_counts_in} would answer for that run. The list surfaces
    # (`GET /api/v1/repositories`, the repositories grid) prime `TestRun#layer_counts` from it so a
    # page of N cards pays one `spec_observations` statement instead of N.
    #
    # A run with no recorded rows has no group at all, so it is ABSENT from the result — and absent
    # means NIL for the caller (`TestRun#preload_layer_counts` primes nil), the same "no detail
    # stored, no mix to state" rule {.run_counts_in} follows; never five zeros. Empty ids ⇒ `{}` with
    # no query. The predicates are {.directory_layer_count_expressions}, not retyped.
    def run_layer_counts_for(test_run_ids)
      return {} if test_run_ids.blank?

      where(test_run_id: test_run_ids)
        .group(:test_run_id)
        .pluck(:test_run_id, *directory_layer_count_expressions)
        .to_h { |id, *counts| [id, DECLARED_LAYER_KEYS.zip(counts.map(&:to_i)).to_h] }
    end

    # The RUN-grain declared-layer mix AND per-layer TIME for MANY runs in ONE grouped read — `{run_id =>
    # [layer_counts, layer_durations]}`, each element exactly what {.layer_counts_in} / {.layer_durations_in}
    # would answer for that run (the SAME predicates: {.directory_layer_count_expressions} for the counts
    # and the {.run_layer_duration_expressions} FILTER aggregates for the time, neither retyped). It is
    # the history window's read (`RepositoryOverview#history_runs`, the Suite growth strips), which needs
    # both series and so pays ONE statement for the pair rather than {.run_layer_counts_for} plus a second.
    # The list surfaces keep {.run_layer_counts_for}: they draw no time and must not start paying for it.
    #
    # A run with no recorded rows has no group at all, so it is ABSENT from the result — NIL for the
    # caller on both seams, never five zeros and never a layer of null seconds. A group exists only where
    # at least one row does, so `recorded?` holds for every run present here, matching {.run_counts_in}.
    # `total_seconds` is NIL (never 0) for a layer none of whose examples was timed. Empty ids ⇒ `{}`
    # with no query. A SUM of example durations — machine time, not wall clock.
    def run_layer_counts_and_durations_for(test_run_ids)
      return {} if test_run_ids.blank?

      width = DECLARED_LAYER_KEYS.length
      where(test_run_id: test_run_ids)
        .group(:test_run_id)
        .pluck(:test_run_id, *directory_layer_count_expressions,
               *run_layer_duration_expressions.map { |sql| Arel.sql(sql) })
        .to_h do |id, *rest|
          counts = DECLARED_LAYER_KEYS.zip(rest.first(width).map(&:to_i)).to_h
          seconds = rest[width, width]
          timed = rest[width * 2, width].map(&:to_i)
          durations = DECLARED_LAYER_KEYS.each_with_index.to_h do |key, index|
            [key, { total_seconds: seconds[index]&.to_f, timed_count: timed[index] }]
          end
          [id, [counts, durations]]
        end
    end

    # The five {.directory_layer_count_expressions}, ALIASED for the run grain — `run_layer_<key>_count`.
    #
    # Aliased for the reason {RUN_READING_COUNTS} is: this projection rides the run-grain read, and
    # `spec/support/observation_grain_reads.rb` partitions this endpoint's reads by SQL only one read
    # can produce. Built lazily because the expressions quote through the live connection.
    def run_layer_count_expressions
      @run_layer_count_expressions ||= DECLARED_LAYER_KEYS.zip(directory_layer_count_expressions).map do |key, expression|
        "#{expression} AS run_layer_#{key}_count"
      end.freeze
    end

    # The run-grain per-layer TIME operands, aliased `run_layer_<key>_seconds` (the summed
    # `duration_seconds` of the layer's rows — SQL NULL when none of them was timed) and
    # `run_layer_<key>_timed_count` (how many of them carried a duration). Five of each, in
    # {DECLARED_LAYER_KEYS} order: ALL the seconds first, then ALL the timed counts, so
    # {.run_counts_in} reads them by the explicit offsets below.
    #
    # Aliased for the reason {.run_layer_count_expressions} is — emitted here and nowhere else — and
    # built from {.declared_layer_predicates} so the predicate is not retyped.
    def run_layer_duration_expressions
      @run_layer_duration_expressions ||= [
        *DECLARED_LAYER_KEYS.zip(declared_layer_predicates).map do |key, predicate|
          "SUM(duration_seconds) FILTER (WHERE #{predicate}) AS run_layer_#{key}_seconds"
        end,
        *DECLARED_LAYER_KEYS.zip(declared_layer_predicates).map do |key, predicate|
          "COUNT(duration_seconds) FILTER (WHERE #{predicate}) AS run_layer_#{key}_timed_count"
        end
      ].freeze
    end

    # Where each group of {.run_counts_in}'s projection starts. Explicit, so appending a further group
    # AFTER these can never shift a slice an earlier group is read by.
    # (Methods rather than constants: they read {DECLARED_LAYER_KEYS}, which is defined further down.)
    def run_layer_count_offset = RUN_READING_COUNTS.length
    def run_layer_seconds_offset = run_layer_count_offset + DECLARED_LAYER_KEYS.length
    def run_layer_timed_offset = run_layer_seconds_offset + DECLARED_LAYER_KEYS.length

    # The RUN-grain per-layer TIME — where the run's example time goes by declared layer:
    # `{unit: {total_seconds:, timed_count:}, … undeclared: {…}}` in {DECLARED_LAYER_KEYS} order. NIL
    # for a run with no recorded per-example rows, the same rule as {.layer_counts_in}.
    # `total_seconds` is NIL (never 0) for a layer none of whose examples was timed. A SUM OF EXAMPLE
    # DURATIONS, not wall clock. The SAME aggregate row as {.reading_counts_in}: see {.run_counts_in}.
    def layer_durations_in(test_run)
      run_counts_in(test_run)[2]
    end

    # ONE single-row aggregate over ONE run answering ALL the run-grain questions — `[IntentReadings,
    # layer_counts, layer_durations]` — so the page pays nothing extra for the layer mix or its time.
    # All memoize on `TestRun`.
    def run_counts_in(test_run)
      counts = where(test_run_id: test_run.id)
               .pick(*[*RUN_READING_COUNTS, *run_layer_count_expressions, *run_layer_duration_expressions]
                        .map { |sql| Arel.sql(sql) })

      width = DECLARED_LAYER_KEYS.length
      readings = IntentReadings.new(authored: counts[0].to_i, derived: counts[1].to_i, unreadable: counts[2].to_i,
                                    recorded: counts[3].to_i)
      return [readings, nil, nil] unless readings.recorded?

      layers = DECLARED_LAYER_KEYS.zip(counts[run_layer_count_offset, width].map(&:to_i)).to_h
      seconds = counts[run_layer_seconds_offset, width]
      timed = counts[run_layer_timed_offset, width].map(&:to_i)
      durations = DECLARED_LAYER_KEYS.each_with_index.to_h do |key, index|
        [key, { total_seconds: seconds[index]&.to_f, timed_count: timed[index] }]
      end

      [readings, layers, durations]
    end
  end
end
