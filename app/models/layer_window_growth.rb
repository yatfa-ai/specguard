# frozen_string_literal: true

# How the DECLARED-LAYER MIX moved ACROSS THE BRANCH WINDOW — per layer (`unit`, `integration`,
# `request`, `system`, `undeclared`): the example count at the oldest comparable run of the window,
# the example count at its newest run, and the signed movement between them.
#
# The window analogue of {LayerRunGrowth} the way {SpecDirectoryWindowGrowth} is the window analogue
# of {SpecDirectoryGrowth}. Run-over-run movement cannot see a slow drift: a team that adds one
# `system` and removes one `unit` every push reads ±1 per push and is never flagged, while over a
# thirty-run window the pyramid has shifted by thirty tests. This is that reading, view-free, so the
# Overview panel line and `GET /api/v1/repository?branch=`'s `layer_growth` read ONE object and
# cannot word or compute the movement differently.
#
# == It compares TWO ENDPOINTS. It is not a series
#
# An example added in run 12 and removed in run 25 reads `±0`. The API serves `basis: "two_endpoints"`
# for that reason, and the series (a `GROUP BY layer, test_run_id` over the window) is deliberately
# not this object: counts come from {TestRun#layer_counts} on the TWO chosen runs only — two
# single-row aggregates over `index_spec_observations_on_test_run_id` — never a scan of the window.
#
# == It compares populations; it matches no tests
#
# Two integers per layer, subtracted — the premise {LayerRunGrowth} stands on. A layer is what each
# example's `@intent` DECLARED; the path is never consulted. `undeclared` means "no @intent declared
# a layer", not "unreadable".
#
# == The baseline walk is SHARED, never re-spelled
#
# {WindowBaseline} is the one walk both window presenters call, so `directory_growth` and
# `layer_growth` name the same baseline commit and the same `runs_back` for one window.
#
# == The gate runs before any read
#
# The four states the walk decides (`anchor_unmeasured`, `no_earlier_run`, `no_measured_baseline`,
# `no_comparable_composition`) are decided from rows already in memory, so a window that cannot be
# compared issues NO `layer_counts` read. Only once a baseline is found are the two ends' mixes
# asked, and the remaining three states come from those reads: a run that WROTE no per-example rows
# has no mix (`TestRun#layer_counts` is nil), and nil is NEVER differenced — against it the whole
# suite would render as appearing from nothing.
class LayerWindowGrowth
  STATES = %i[anchor_unmeasured no_earlier_run no_measured_baseline no_comparable_composition
              neither_recorded baseline_unrecorded anchor_unrecorded comparable].freeze

  # @param runs [RunWindow, Array<TestRun>] the loaded window, as {SpecDirectoryWindowGrowth.for}
  #   takes it (a bare array is read oldest first).
  def self.for(runs, branch: nil)
    baseline = WindowBaseline.for(runs)
    return new(state: baseline.state, baseline: baseline, branch: branch) unless baseline.found?

    anchor_counts = baseline.anchor.layer_counts
    baseline_counts = baseline.run.layer_counts
    if anchor_counts.nil? && baseline_counts.nil?
      return new(state: :neither_recorded, baseline: baseline, branch: branch)
    end
    return new(state: :baseline_unrecorded, baseline: baseline, branch: branch) if baseline_counts.nil?
    return new(state: :anchor_unrecorded, baseline: baseline, branch: branch) if anchor_counts.nil?

    rows = SpecObservation::DECLARED_LAYER_KEYS.index_with do |layer|
      Row.new(layer: layer, baseline_count: baseline_counts.fetch(layer), anchor_count: anchor_counts.fetch(layer))
    end

    new(state: :comparable, baseline: baseline, branch: branch, rows: rows)
  end

  def initialize(state:, baseline:, branch: nil, rows: {})
    @state = state
    @baseline = baseline
    @branch = branch
    @rows = rows
  end

  # Which of the eight states this is — one comparable, seven not. Different facts about the window,
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

  # The recorded populations each end's mix was counted over (the five layers partition the recorded
  # rows, so these are sums). Only meaningful when comparable.
  def baseline_recorded_count = rows.values.sum(&:baseline_count)

  def anchor_recorded_count = rows.values.sum(&:anchor_count)

  # The layers a one-line reading names: any layer present on either end, plus `undeclared` always
  # (a run declaring nothing reads "undeclared N", never a blank). Absent layers are omitted from
  # the SENTENCE only; the API serves all five.
  def reading_rows
    rows.values.select { |row| row.baseline_count.positive? || row.anchor_count.positive? || row.layer == :undeclared }
  end

  # `unit ±0 · request +40 · undeclared −12 over 30 runs` — the ONE wording the panel line and any
  # other surface use. "Over N runs" is the span the comparison covers (endpoints included), which
  # can be shorter than the window when the walk stepped over runs.
  def label
    movement = reading_rows.map { |row| "#{row.layer} #{row.change_label}" }.join(" · ")

    "#{movement} over #{covered_run_count} runs"
  end

  # The same row — operands, signed `change`, `±0`/U+2212 wording — as {LayerRunGrowth}, reused and
  # not copied, so the two layer panels on one page cannot word a movement differently.
  Row = LayerRunGrowth::Row
end
