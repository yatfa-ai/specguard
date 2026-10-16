# frozen_string_literal: true

# Which AREAS of the suite got SLOWER or FASTER ACROSS THE BRANCH WINDOW — per directory: the summed
# example duration at the oldest comparable run of the window, the summed example duration at its
# newest run, and the signed movement between them, ranked by how far each moved.
#
# The empty cell of the area/layer × count/time × push/window grid. {SpecDirectoryWindowGrowth} is
# area COUNT across the window, {SpecDirectoryRuntimeGrowth} is area TIME across one push, and
# {LayerWindowRuntimeGrowth} is layer TIME across the window; this is area TIME across the window. A
# directory whose specs crept from 40s to 110s over thirty pushes reads `±0` examples on the first
# and a couple of seconds per push on the second, and the page could name the LAYER that crept and
# never the AREA.
#
# == A composition, not a new query
#
# The read is {SpecObservation.directory_runtime_growth_between}, which takes ANY two runs; handed the
# window's anchor and baseline instead of a run and its predecessor it is the window comparison, with
# its plan certification intact. The baseline is {WindowBaseline}'s, the same walk
# {SpecDirectoryWindowGrowth}, {LayerWindowGrowth} and {LayerWindowRuntimeGrowth} share, so all four
# name one baseline commit and one `runs_back` for one window. The row is
# {SpecDirectoryRuntimeGrowth::Row}'s (subclassed only for the sentences that name what the movement
# was measured against), so the "Not timed" / timing-gap semantics are one spelling for both panels.
#
# == It compares TWO ENDPOINTS. It is not a series, and it says so
#
# An area slowed in run 12 and sped up again in run 25 reads `±0` here. The per-area series across
# the window is deliberately not this object: it would be the first read to scan a whole window
# unnarrowed. Two run ids is the certified shape, and that is what this reads.
#
# == A move is not a slowdown
#
# Sums of example durations, subtracted — populations, not tests. A renamed directory reads as one
# area gaining time and another losing it; an area that gained examples gains time with no test any
# slower; summed machine time is not wall clock. No threshold or verdict is applied.
#
# == The gate is the count window's, not the Overview runtime delta's
#
# {WindowBaseline}'s two predicates (`suite_size_measured?`, `assembled_like?`) — NOT the runtime
# delta's `timed_shard_count` check, for the reason {SpecDirectoryRuntimeGrowth} gives: this sums
# per-example rows (machine time), so there is no MAX over shards to guard. The four walk states are
# decided from rows already in memory, so a window that cannot be compared issues NO observation
# read; a comparable one issues exactly one.
class SpecDirectoryWindowRuntimeGrowth
  include SpecDirectoryWindowContext

  STATES = %i[anchor_unmeasured no_earlier_run no_measured_baseline no_comparable_composition
              neither_recorded baseline_unrecorded anchor_unrecorded
              neither_timed baseline_untimed anchor_untimed comparable].freeze

  # Builds the comparison, or the stated reason there isn't one.
  #
  # @param runs [RunWindow, Array<TestRun>] the loaded window, as {SpecDirectoryWindowGrowth.for}
  #   takes it (read OLDEST first; the order is {WindowBaseline}'s to enforce).
  # @param branch [String, nil] the branch every figure is drawn on, for the caption.
  # @param limit [Integer] the cap on listed areas; `directory_count` is counted before it.
  # @param layer [String, Symbol, nil] ONE declared layer to narrow the comparison to — nil is the
  #   un-narrowed comparison. With a layer the read's window totals are the LAYER's, so the RECORDED
  #   states are decided at run grain off {TestRun#intent_readings}, and the TIMED states fire only on
  #   an end that HAS examples of the layer ({TestRun#layer_counts}): a layer-empty end is a new or
  #   removed area, not an untimed one. A layer empty at the baseline only is `comparable` with every
  #   area `new_area?`; at the anchor only, every area `removed_area?`; at both, `comparable` with no
  #   rows ({#layer_empty?}) — a defined answer, not `neither_recorded`.
  def self.for(runs, branch: nil, limit: SpecObservation::RETIMED_DIRECTORIES_LIMIT, layer: nil)
    resolve_window(runs, branch: branch, layer: layer) do |baseline, context, narrowed|
      sides = narrowed && { baseline_has_layer: baseline.run.layer_counts.fetch(narrowed.to_sym, 0).positive?,
                            anchor_has_layer: baseline.anchor.layer_counts.fetch(narrowed.to_sym, 0).positive? }

      from_tuples(SpecObservation.directory_runtime_growth_between(baseline.anchor, baseline.run,
                                                                   limit: limit, layer: narrowed),
                  sides, **context)
    end
  end

  # The five totals ride on every row and are identical on all of them, so they are read off the
  # first; `to_i` on the nil of an empty read. Every state carries them (the read has paid for them),
  # and the RECORDED questions are asked before the TIMED ones, which only ever fire on an end that
  # has rows — see {SpecDirectoryRuntimeGrowth.from_tuples}, whose ordering this mirrors.
  def self.from_tuples(tuples, sides, **context)
    _path, _base_s, _anchor_s, _base_rec, _anchor_rec, _base_timed, _anchor_timed,
      directory_count, baseline_recorded, anchor_recorded, baseline_timed, anchor_timed = tuples.first

    totals = { directory_count: directory_count.to_i,
               baseline_recorded_count: baseline_recorded.to_i, anchor_recorded_count: anchor_recorded.to_i,
               baseline_timed_count: baseline_timed.to_i, anchor_timed_count: anchor_timed.to_i }

    if sides
      baseline_untimed = sides.fetch(:baseline_has_layer) && baseline_timed.to_i.zero?
      anchor_untimed = sides.fetch(:anchor_has_layer) && anchor_timed.to_i.zero?
      return new(state: :neither_timed, **context, **totals) if baseline_untimed && anchor_untimed
      return new(state: :baseline_untimed, **context, **totals) if baseline_untimed
      return new(state: :anchor_untimed, **context, **totals) if anchor_untimed
    else
      return new(state: :neither_recorded, **context, **totals) if baseline_recorded.to_i.zero? &&
                                                                   anchor_recorded.to_i.zero?
      return new(state: :baseline_unrecorded, **context, **totals) if baseline_recorded.to_i.zero?
      return new(state: :anchor_unrecorded, **context, **totals) if anchor_recorded.to_i.zero?
      return new(state: :neither_timed, **context, **totals) if baseline_timed.to_i.zero? &&
                                                                anchor_timed.to_i.zero?
      return new(state: :baseline_untimed, **context, **totals) if baseline_timed.to_i.zero?
      return new(state: :anchor_untimed, **context, **totals) if anchor_timed.to_i.zero?
    end

    rows = tuples.map do |path, baseline_s, anchor_s, baseline_rec, anchor_rec, baseline_t, anchor_t, *|
      Row.new(path: path, previous_seconds: baseline_s, latest_seconds: anchor_s,
              previous_recorded_count: baseline_rec.to_i, latest_recorded_count: anchor_rec.to_i,
              previous_timed_count: baseline_t.to_i, latest_timed_count: anchor_t.to_i)
    end

    new(state: :comparable, rows: rows, **context, **totals)
  end
  private_class_method :from_tuples

  def initialize(baseline_timed_count: 0, anchor_timed_count: 0, **window)
    super(**window)
    @baseline_timed_count = baseline_timed_count
    @anchor_timed_count = anchor_timed_count
  end

  # How many per-example rows each end recorded ({#baseline_recorded_count}, {#anchor_recorded_count})
  # and how many carried a timing — the denominators every figure is stated against. The LAYER's own
  # when a layer was asked.
  attr_reader :baseline_timed_count, :anchor_timed_count

  # At least one LISTED area has both ends timed and did not move.
  def any_unmoved? = rows.any? { |row| row.comparable? && !row.moved? }

  # At least one LISTED area has no movement to state because an end was never timed.
  def any_untimed? = rows.any? { |row| !row.comparable? }

  # At least one LISTED area is a TIMING GAP specifically: both ends ran it, one reported no duration.
  def any_timing_gap? = rows.any?(&:timing_gap?)

  # There is a table worth rendering: some listed area either moved or has an absence to disclose.
  def anything_to_show? = any_movement? || any_untimed?

  # One area's TIME movement across the window — {SpecDirectoryRuntimeGrowth::Row}, with every
  # sentence that names WHAT the movement was measured against re-worded: "than the previous run on
  # this branch" is false of a figure taken across a window. `previous_*`/`latest_*` keep the
  # parent's names (the aggregate's own two sides) and read as the BASELINE and ANCHOR ends here.
  class Row < SpecDirectoryRuntimeGrowth::Row
    def baseline_label = previous_label

    def anchor_label = latest_label

    def change_reading
      return new_area_reading if new_area?
      return removed_area_reading if removed_area?
      return untimed_reading unless comparable?
      return "took the same time as it did in the baseline run of this window" unless moved?

      "#{SpecObservation.humanized_duration(change.abs)} " \
        "#{change.negative? ? "faster" : "slower"} than the baseline run of this window"
    end

    private

    def new_area_reading
      return "an area the baseline run did not record, and the newest run reported no timing for it" if latest_seconds.nil?

      "#{latest_label} of examples, an area the baseline run did not record"
    end

    def removed_area_reading
      return "an area the newest run does not have, and the baseline run reported no timing for it" if previous_seconds.nil?

      "#{previous_label} of examples in the baseline run and none now"
    end

    def untimed_reading
      return "neither end of this window reported a timing for this area" if previous_seconds.nil? && latest_seconds.nil?
      return "the newest run reported no timing for this area, so there is nothing to compare" if latest_seconds.nil?

      "the baseline run of this window reported no timing for this area, so there is nothing to compare"
    end
  end
end
