# frozen_string_literal: true

# How the TIME each DECLARED LAYER accounts for moved between the latest run and the previous run ON
# THE SAME BRANCH — per layer (`unit`, `integration`, `request`, `system`, `undeclared`): the summed
# example duration then, the summed example duration now, and the signed movement between them.
#
# == Why this is a sibling of {LayerRunGrowth} and not a column added to it
#
# {LayerRunGrowth} differences example COUNTS. A `sleep` added to a shared request-spec `before`
# adds zero examples, so it reads `request ±0` there. And `SpecDirectoryRuntimeGrowth` is per PATH,
# while a layer cuts across directories (what `@intent` declared; the path is never consulted), so
# no sum of its rows yields a layer's movement. "Did my push make the request layer 40s slower?" is
# a third question, answered by neither.
#
# == It compares populations; it matches no tests
#
# Two sums per layer, subtracted. Both operands are already loaded, at no query of their own:
# `TestRun#layer_durations` rides the same memoized single-row aggregate as `layer_counts`, which
# {LayerRunGrowth.for} already asks of the previous run. No example crosses the run boundary.
# A test that changes its declared `@intent` layer reads as one layer gaining time and another
# losing it; nothing here can tell that from a real regression and a real win.
#
# == The gate runs before any read
#
# {LayerRunGrowth}'s, verbatim and in the same order: `suite_size_measured?` on each side and
# `assembled_like?` across them are decided from the two runs already in memory, so a pair that
# cannot compare asks neither run for its layer mix. The recorded-arm states then use the nil that
# `layer_durations` is exactly when a run wrote no per-example rows.
#
# == The untimed arms
#
# `total_seconds` is nil, never 0, for a layer none of whose examples was timed (SUM skips NULLs
# silently), and `duration_seconds` is nullable by design. A run that recorded rows but timed none
# of them has nothing to subtract, and rendering its layers as `0.00s` would read the telemetry gap
# as a speedup. So three more states, decided from whether ANY layer on a side carries a timing:
# `neither_timed`, `previous_untimed`, `latest_untimed`. Inside a comparable pair a single layer
# can still be untimed on one side; that layer's `change` is nil, never a difference against zero.
#
# The caller guards the nil previous run, as {LayerRunGrowth} does — there is no "no previous run"
# state here.
class LayerRuntimeGrowth
  STATES = %i[latest_unmeasured previous_unmeasured assembled_differently
              neither_recorded previous_unrecorded latest_unrecorded
              neither_timed previous_untimed latest_untimed comparable].freeze

  def self.for(test_run, previous_test_run)
    return new(state: :latest_unmeasured) unless test_run.suite_size_measured?
    return new(state: :previous_unmeasured) unless previous_test_run.suite_size_measured?
    return new(state: :assembled_differently) unless test_run.assembled_like?(previous_test_run)

    latest = test_run.layer_durations
    previous = previous_test_run.layer_durations
    return new(state: :neither_recorded) if latest.nil? && previous.nil?
    return new(state: :previous_unrecorded) if previous.nil?
    return new(state: :latest_unrecorded) if latest.nil?

    latest_timed = timed?(latest)
    previous_timed = timed?(previous)
    return new(state: :neither_timed) if !latest_timed && !previous_timed
    return new(state: :previous_untimed) unless previous_timed
    return new(state: :latest_untimed) unless latest_timed

    latest_counts = test_run.layer_counts
    previous_counts = previous_test_run.layer_counts
    rows = SpecObservation::DECLARED_LAYER_KEYS.index_with do |layer|
      Row.new(layer: layer,
              baseline_seconds: previous.fetch(layer)[:total_seconds],
              anchor_seconds: latest.fetch(layer)[:total_seconds],
              baseline_timed_count: previous.fetch(layer)[:timed_count],
              anchor_timed_count: latest.fetch(layer)[:timed_count],
              baseline_count: previous_counts.fetch(layer),
              anchor_count: latest_counts.fetch(layer))
    end

    new(state: :comparable, rows: rows)
  end

  # Some layer on this side carries a real summed duration.
  def self.timed?(durations)
    durations.values.any? { |figures| !figures[:total_seconds].nil? }
  end
  private_class_method :timed?

  def initialize(state:, rows: {})
    @state = state
    @rows = rows
  end

  # Which of the ten states this is — one comparable, nine not. Different facts about the two runs,
  # so the one that applies is named rather than collapsed into "cannot compare".
  attr_reader :state

  # `{unit: Row, … undeclared: Row}` in `SpecObservation::DECLARED_LAYER_KEYS` order; empty in every
  # non-comparable state.
  attr_reader :rows

  def comparable? = state == :comparable

  # The layers a one-line reading names: any layer with examples on either side, plus `undeclared`
  # always. Absent layers are omitted from the SENTENCE only; the API serves all five.
  def reading_rows
    rows.values.select { |row| row.baseline_count.positive? || row.anchor_count.positive? || row.layer == :undeclared }
  end

  # `unit ±0 · request +41.20s · undeclared not reported`
  def label
    reading_rows.map { |row| "#{row.layer} #{row.change_label}" }.join(" · ")
  end

  Row = Struct.new(:layer, :baseline_seconds, :anchor_seconds, :baseline_timed_count, :anchor_timed_count,
                   :baseline_count, :anchor_count, keyword_init: true) do
    # Both sides summed a real number of seconds for this layer.
    def comparable? = !baseline_seconds.nil? && !anchor_seconds.nil?

    # Signed; nil unless BOTH sides timed this layer — never a difference against a NULL read as 0.
    def change = comparable? ? anchor_seconds - baseline_seconds : nil

    def moved? = comparable? && !change.zero?

    # `±0` for a layer that did not move (`+0` claims a direction it does not have), a true minus
    # (U+2212), and `SpecObservation.humanized_duration` for the magnitude — so a nil says "not
    # reported" and a sub-centisecond move says "< 0.01s", never `0.00s`.
    def change_label
      return SpecObservation.humanized_duration(nil) unless comparable?
      return "±0" unless moved?

      "#{change.negative? ? "−" : "+"}#{SpecObservation.humanized_duration(change.abs)}"
    end
  end
end
