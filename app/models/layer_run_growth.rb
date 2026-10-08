# frozen_string_literal: true

# How the DECLARED-LAYER MIX moved between the latest run and the previous run ON THE SAME BRANCH —
# per layer (`unit`, `integration`, `request`, `system`, `undeclared`): the example count then, the
# example count now, and the signed movement between them.
#
# `TestRun#layer_counts` answers "what is the pyramid of THIS run"; every other headline figure
# (suite size, per-area count, per-area runtime) already has a "versus the previous run" companion
# and the mix did not, so "did my last push move the pyramid?" was unanswerable. This is that
# companion, view-free, so the Overview panel line and `GET /api/v1/repository`'s
# `layer_run_growth` read ONE object and cannot word or compute the movement differently.
#
# == It compares populations; it matches no tests
#
# Two integers per layer, subtracted. No example crosses the run boundary and nothing here pairs an
# example with another, which is the premise `SpecDirectoryGrowth` stands on and the one
# `example_id`'s positional instability forces. A layer is what each example's `@intent` DECLARED:
# the path is never consulted, so an example declaring `unit` under spec/requests moves `unit`.
# `undeclared` keeps its meaning — "no @intent declared a layer", not "unreadable".
#
# == The gate runs before any read
#
# Modelled on {SpecDirectoryGrowth}: `suite_size_measured?` on each side and `assembled_like?`
# across them — the Overview delta's own predicates, reused rather than re-spelled — decide three
# states from the two runs already in memory, so a page that cannot compare issues NO read of the
# previous run's layer mix. Only once the gate passes is `previous.layer_counts` asked (one more
# single-row aggregate over `index_spec_observations_on_test_run_id`; no new query shape), and the
# three remaining states are decided from those two reads: a run that WROTE no per-example rows
# has no mix (`TestRun#layer_counts` is nil) and differencing against it would render the whole
# suite as appearing from nothing.
#
# The caller guards the nil previous run, as `RepositoryOverview#spec_directory_growth` does — this
# object has no "no previous run" state of its own.
class LayerRunGrowth
  STATES = %i[latest_unmeasured previous_unmeasured assembled_differently
              neither_recorded previous_unrecorded latest_unrecorded comparable].freeze

  def self.for(test_run, previous_test_run)
    return new(state: :latest_unmeasured) unless test_run.suite_size_measured?
    return new(state: :previous_unmeasured) unless previous_test_run.suite_size_measured?
    return new(state: :assembled_differently) unless test_run.assembled_like?(previous_test_run)

    latest = test_run.layer_counts
    previous = previous_test_run.layer_counts
    return new(state: :neither_recorded) if latest.nil? && previous.nil?
    return new(state: :previous_unrecorded) if previous.nil?
    return new(state: :latest_unrecorded) if latest.nil?

    rows = SpecObservation::DECLARED_LAYER_KEYS.index_with do |layer|
      Row.new(layer: layer, baseline_count: previous.fetch(layer), anchor_count: latest.fetch(layer))
    end

    new(state: :comparable, rows: rows)
  end

  def initialize(state:, rows: {})
    @state = state
    @rows = rows
  end

  # Which of the seven states this is — one comparable, six not. Different facts about the two
  # runs, so the one that applies is named rather than collapsed into "cannot compare".
  attr_reader :state

  # `{unit: Row, … undeclared: Row}` in `SpecObservation::DECLARED_LAYER_KEYS` order; empty in every
  # non-comparable state.
  attr_reader :rows

  def comparable? = state == :comparable

  # The recorded populations each side's mix was counted over. Only meaningful (and only
  # non-zero) when comparable; the five layers partition the recorded rows, so these are sums.
  def baseline_recorded_count = rows.values.sum(&:baseline_count)

  def anchor_recorded_count = rows.values.sum(&:anchor_count)

  # The layers a one-line reading names: any layer present on either side, plus `undeclared`
  # always (a run declaring nothing reads "undeclared N", never a blank). Absent layers are
  # omitted from the SENTENCE only; the API serves all five.
  def reading_rows
    rows.values.select { |row| row.baseline_count.positive? || row.anchor_count.positive? || row.layer == :undeclared }
  end

  # `unit ±0 · request +40 · undeclared −12`
  def label
    reading_rows.map { |row| "#{row.layer} #{row.change_label}" }.join(" · ")
  end

  Row = Struct.new(:layer, :baseline_count, :anchor_count, keyword_init: true) do
    # Signed; a layer that did not move is a measured 0, never absent.
    def change = anchor_count - baseline_count

    # `±0` for a layer that did not move — "compared, and it did not move" is a real answer and
    # `+0` claims a direction it does not have (the rule `ApplicationHelper#suite_size_change`
    # sets). A true minus (U+2212), for that helper's typographic reason.
    def change_label
      return "±0" if change.zero?

      "#{change.negative? ? "−" : "+"}#{ActiveSupport::NumberHelper.number_to_delimited(change.abs)}"
    end
  end
end
