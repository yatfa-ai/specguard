# frozen_string_literal: true

# How the TIME each DECLARED LAYER accounts for moved ACROSS THE BRANCH WINDOW — per layer (`unit`,
# `integration`, `request`, `system`, `undeclared`): the summed example duration at the oldest
# comparable run of the window, the summed example duration at its newest run, and the signed
# movement between them.
#
# The time analogue of {LayerWindowGrowth} the way {LayerRuntimeGrowth} is the time analogue of
# {LayerRunGrowth}. A slower shared request-spec fixture that adds ~4s per push reads `request +4.00s`
# on {LayerRuntimeGrowth} every push, and `request ±0` on {LayerWindowGrowth} (no example was added),
# while over a thirty-run window the layer gained two minutes. This is the reading that answers "is
# my request layer getting slower on main?", view-free, so the Overview panel line and
# `GET /api/v1/repository?branch=`'s `layer_runtime_window_growth` read ONE object and cannot word or
# compute the movement differently.
#
# == It compares TWO ENDPOINTS. It is not a series
#
# A fixture slowed in run 12 and sped up again in run 25 reads `±0`. The API serves
# `basis: "two_endpoints"` for that reason; a per-layer series across the window is deliberately not
# this object. Both operands come from {TestRun#layer_durations} (and `layer_counts`) on the TWO
# chosen runs only — the same memoized single-row aggregate {LayerWindowGrowth} already reads, so
# this adds no observation read of its own.
#
# == A move is not a slowdown
#
# Two sums per layer, subtracted — populations, not tests. A test that changes its declared `@intent`
# layer reads as one layer gaining time and another losing it; a layer that gained examples gains
# time with no test any slower; and summed machine time is not wall clock (it can exceed it on a
# parallel or sharded run). Nothing here can tell those from a real regression and a real win, and
# no threshold or verdict is applied.
#
# == The baseline walk and the gate are the count window's, SHARED
#
# {WindowBaseline} is the one walk, so this names the same baseline commit and the same `runs_back`
# as `directory_growth` and `layer_growth` for one window. Its gate predicates
# (`suite_size_measured?`, `assembled_like?`) are used as they are — NOT the Overview runtime delta's
# `timed_shard_count` check, because per-example rows are summed machine time, not a max over shards.
# The four states the walk decides are decided from rows already in memory, so a window that cannot
# be compared issues NO read.
#
# == The recorded and untimed arms
#
# `layer_durations` is nil exactly when a run wrote no per-example rows, and nil is NEVER differenced.
# A run that recorded rows but timed none of them (`total_seconds` nil on every layer) has nothing to
# subtract either, so three more states mirror {LayerRuntimeGrowth}'s. Inside a comparable window a
# single layer can still be untimed on one end; that layer's `change` is nil, never a difference
# against zero.
class LayerWindowRuntimeGrowth
  STATES = %i[anchor_unmeasured no_earlier_run no_measured_baseline no_comparable_composition
              neither_recorded baseline_unrecorded anchor_unrecorded
              neither_timed baseline_untimed anchor_untimed comparable].freeze

  # @param runs [RunWindow, Array<TestRun>] the loaded window, as {LayerWindowGrowth.for} takes it.
  def self.for(runs, branch: nil)
    baseline = WindowBaseline.for(runs)
    return new(state: baseline.state, baseline: baseline, branch: branch) unless baseline.found?

    anchor_durations = baseline.anchor.layer_durations
    baseline_durations = baseline.run.layer_durations
    if anchor_durations.nil? && baseline_durations.nil?
      return new(state: :neither_recorded, baseline: baseline, branch: branch)
    end
    return new(state: :baseline_unrecorded, baseline: baseline, branch: branch) if baseline_durations.nil?
    return new(state: :anchor_unrecorded, baseline: baseline, branch: branch) if anchor_durations.nil?

    anchor_timed = LayerRuntimeGrowth.timed?(anchor_durations)
    baseline_timed = LayerRuntimeGrowth.timed?(baseline_durations)
    return new(state: :neither_timed, baseline: baseline, branch: branch) if !anchor_timed && !baseline_timed
    return new(state: :baseline_untimed, baseline: baseline, branch: branch) unless baseline_timed
    return new(state: :anchor_untimed, baseline: baseline, branch: branch) unless anchor_timed

    anchor_counts = baseline.anchor.layer_counts
    baseline_counts = baseline.run.layer_counts
    rows = SpecObservation::DECLARED_LAYER_KEYS.index_with do |layer|
      Row.new(layer: layer,
              baseline_seconds: baseline_durations.fetch(layer)[:total_seconds],
              anchor_seconds: anchor_durations.fetch(layer)[:total_seconds],
              baseline_timed_count: baseline_durations.fetch(layer)[:timed_count],
              anchor_timed_count: anchor_durations.fetch(layer)[:timed_count],
              baseline_count: baseline_counts.fetch(layer),
              anchor_count: anchor_counts.fetch(layer))
    end

    new(state: :comparable, baseline: baseline, branch: branch, rows: rows)
  end

  def initialize(state:, baseline:, branch: nil, rows: {})
    @state = state
    @baseline = baseline
    @branch = branch
    @rows = rows
  end

  # Which of the eleven states this is — one comparable, ten not. Different facts about the window,
  # so the one that applies is named rather than collapsed into "cannot compare".
  attr_reader :state

  attr_reader :branch

  # `{unit: Row, … undeclared: Row}` in `SpecObservation::DECLARED_LAYER_KEYS` order; empty in every
  # non-comparable state.
  attr_reader :rows

  def comparable? = state == :comparable

  def anchor_run = @baseline.anchor

  # The oldest comparable run; nil in the states where the walk found none.
  def baseline_run = @baseline.run

  def runs_back = @baseline.runs_back

  def window_run_count = @baseline.window_run_count

  # How many runs the comparison spans, endpoints included.
  def covered_run_count = runs_back + 1

  # The layers a one-line reading names: any layer with examples on either end, plus `undeclared`
  # always. Absent layers are omitted from the SENTENCE only; the API serves all five.
  def reading_rows
    rows.values.select { |row| row.baseline_count.positive? || row.anchor_count.positive? || row.layer == :undeclared }
  end

  # `unit ±0 · request +2m 0s over 30 runs` — the ONE wording the panel line and any other surface use.
  def label
    movement = reading_rows.map { |row| "#{row.layer} #{row.change_label}" }.join(" · ")

    "#{movement} over #{covered_run_count} runs"
  end

  # The same row — operands, signed `change`, `±0`/U+2212 wording, nil for a layer untimed on one
  # end — as {LayerRuntimeGrowth}, reused and not copied.
  Row = LayerRuntimeGrowth::Row
end
