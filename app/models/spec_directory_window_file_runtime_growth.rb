# frozen_string_literal: true

# Which FILES of ONE area got SLOWER or FASTER ACROSS THE BRANCH WINDOW — per spec file: the summed
# example duration at the oldest comparable run of the window, the summed example duration at its
# newest run, and the signed movement between them, ranked by how far each moved.
#
# The last empty cell of the {area, file} × {count, time} × {last push, branch window} grid.
# {SpecDirectoryWindowRuntimeGrowth} ("Areas that got slower or faster over the window") ends at the
# area, and the only file-TIME object before this one, {SpecDirectoryFileRuntimeGrowth}, compares the
# last push alone: a file that crept from 8s to 60s over thirty pushes moved a couple of seconds per
# push and was invisible at both.
#
# == A composition, not a new query
#
# {SpecObservation.file_runtime_growth_between} takes ANY two runs (it uses only their ids); handed
# the window's anchor and baseline instead of a run and its predecessor it IS the window comparison
# — the move {SpecDirectoryWindowFileGrowth} makes for counts and {SpecDirectoryWindowRuntimeGrowth}
# makes for area time. No new SQL, no migration, and no change to the read, to the parents or to
# {WindowBaseline}.
#
# == The gate is the PARENT'S verdict, not a second spelling of it
#
# `.for` takes the already-built {SpecDirectoryWindowRuntimeGrowth} and returns a refusal object —
# with ZERO observation reads — the moment it is not comparable, in all ELEVEN of its states. The
# state, baseline, anchor, `runs_back`, branch and layer are carried verbatim, so the panel, the API
# block and the area panel above them can only name one baseline commit for one window. The RECORDED
# and TIMED states are facts about a RUN and are never re-derived from this area's totals: an area
# only the anchor timed has zero baseline-side timed rows, which would spell `baseline_untimed`
# identically and mean something else ("this area is new" vs. "the baseline run reported no timings
# anywhere"). With `layer`, a layer empty at one end reads as `new_file?` / `removed_file?` rows,
# never as an unrecorded or untimed state.
#
# Like its siblings it takes NO `timed_shard_count` guard: this sums per-example rows (machine time),
# so there is no MAX over shards to fold. See {SpecDirectoryFileRuntimeGrowth}.
#
# == It compares TWO ENDPOINTS. It is not a series, and it says so
#
# A file that slowed in run 12 and sped up again in run 25 reads `±0` here, and a file that was MOVED
# reads as one file removed beside one new. It sums rows per file in each of two runs and subtracts;
# no example is paired with another across the boundary.
#
# == One object, so the panel and the API cannot disagree
#
# Every figure comes back from the one grouped aggregate that returned the rows (windows counted
# before the `LIMIT`); the web partial and `RepositoryGrowthSerializer` both read this object.
class SpecDirectoryWindowFileRuntimeGrowth
  # Builds the comparison for one area, or the parent's stated refusal.
  #
  # @param path [String] the asked area, as asked.
  # @param window_growth [SpecDirectoryWindowRuntimeGrowth] the already-built parent for this window.
  # @param limit [Integer] the cap on listed files; `file_count` is counted before it.
  # @param layer [String, Symbol, nil] ONE declared layer to narrow to — the parent's layer, passed
  #   through to the read.
  def self.for(path, window_growth:, limit: SpecObservation::SPEC_DIRECTORY_FILE_RUNTIME_GROWTH_LIMIT, layer: nil)
    layer = layer&.to_s
    return new(path: path, window_growth: window_growth, layer: layer) unless window_growth.comparable?

    tuples = SpecObservation.file_runtime_growth_between(window_growth.anchor_run, window_growth.baseline_run,
                                                         path, limit: limit, layer: layer)
    from_tuples(path, window_growth, tuples, layer)
  end

  # The five window totals ride on every row and are identical on all of them, so they are read off
  # the first; `to_i` over the nil of an empty read, where zero files and zero rows is the honest
  # count. NO STATE IS DERIVED HERE: the parent's verdict is the only one, and an empty read is a
  # `comparable` answer with no rows.
  def self.from_tuples(path, window_growth, tuples, layer)
    rows = tuples.map do |file_path, baseline_s, anchor_s, baseline_rec, anchor_rec, *|
      Row.new(path: file_path, previous_seconds: baseline_s, latest_seconds: anchor_s,
              previous_recorded_count: baseline_rec.to_i, latest_recorded_count: anchor_rec.to_i)
    end

    _path, _base_s, _anchor_s, _base_rec, _anchor_rec, _base_t, _anchor_t,
      file_count, baseline_recorded, anchor_recorded, baseline_timed, anchor_timed = tuples.first

    new(path: path, window_growth: window_growth, rows: rows, file_count: file_count.to_i,
        baseline_recorded_count: baseline_recorded.to_i, anchor_recorded_count: anchor_recorded.to_i,
        baseline_timed_count: baseline_timed.to_i, anchor_timed_count: anchor_timed.to_i, layer: layer)
  end
  private_class_method :from_tuples

  def initialize(path:, window_growth:, rows: [], file_count: 0, baseline_recorded_count: 0,
                 anchor_recorded_count: 0, baseline_timed_count: 0, anchor_timed_count: 0, layer: nil)
    @path = path
    @window_growth = window_growth
    @rows = rows
    @file_count = file_count
    @baseline_recorded_count = baseline_recorded_count
    @anchor_recorded_count = anchor_recorded_count
    @baseline_timed_count = baseline_timed_count
    @anchor_timed_count = anchor_timed_count
    @layer = layer&.to_s
  end

  # The area that was asked for, as it was asked for. Held even when nothing came back.
  attr_reader :path

  # The comparison, largest movement in seconds first (files an end did not time last). Never longer
  # than the limit, empty in every non-comparable state.
  attr_reader :rows

  # How many spec files the comparison COVERED in this area, counted before the `LIMIT` and
  # therefore not `rows.size`.
  attr_reader :file_count

  # How many per-example rows each end recorded IN THIS AREA, and how many of those carried a timing
  # — deliberately not the parent's identically-named whole-run figures.
  attr_reader :baseline_recorded_count, :anchor_recorded_count
  attr_reader :baseline_timed_count, :anchor_timed_count

  # The declared layer this drill-in was narrowed to, or nil.
  attr_reader :layer

  # The parent's verdict, carried verbatim.
  def state = window_growth.state

  def comparable? = window_growth.comparable?

  # What the parent carries about the window, forwarded so the captions, the contract block and the
  # area panel can never name a different baseline for one window.
  delegate :branch, :window_run_count, :anchor_run, :baseline_run, :runs_back, :covered_run_count,
           :shortened?, :skipped_count, :skipped_unmeasured_count, :skipped_assembled_differently_count,
           to: :window_growth

  def layer? = !layer.nil?

  # Either end recorded at least one example in this area.
  def recorded? = rows.any?

  def truncated? = file_count > rows.size

  # At least one listed file's summed duration actually moved.
  def any_movement? = rows.any?(&:moved?)

  # At least one LISTED file has both ends timed and did not move.
  def any_unmoved? = rows.any? { |row| row.comparable? && !row.moved? }

  # At least one LISTED file has no movement to state because an end was never timed (or it is new
  # or removed).
  def any_untimed? = rows.any? { |row| !row.comparable? }

  # At least one LISTED file is a TIMING GAP specifically: both ends ran it, one reported no duration.
  def any_timing_gap? = rows.any?(&:timing_gap?)

  # There is a table worth rendering: some listed file either moved or has an absence to disclose.
  def anything_to_show? = any_movement? || any_untimed?

  # One spec file's TIME movement across the window — {SpecDirectoryFileRuntimeGrowth::Row}, plus the
  # display spellings that class deliberately omits (it had no panel), worded against the BASELINE
  # run of the window: "than the previous run on this branch" is false of a figure taken across a
  # window. `previous_*`/`latest_*` keep the parent's names and read as the BASELINE and ANCHOR ends.
  #
  # Durations only through {SpecObservation.humanized_duration}, the one seam that keeps an untimed
  # side reading "not reported" instead of "0.00s".
  class Row < SpecDirectoryFileRuntimeGrowth::Row
    def baseline_label = SpecObservation.humanized_duration(previous_seconds)

    def anchor_label = SpecObservation.humanized_duration(latest_seconds)

    # What moved, rendered. Three different absences, three different words — a file on one side only
    # is not a file the telemetry missed. `±0` for a compared file that did not move; a true minus
    # (U+2212), as every signed figure on this page uses.
    def change_label
      return "New file" if new_file?
      return "File removed" if removed_file?
      return "Not timed" unless comparable?
      return "±0" unless moved?

      "#{change.negative? ? "−" : "+"}#{SpecObservation.humanized_duration(change.abs)}"
    end

    # The same fact in words, for the `aria-label` on that cell.
    def change_reading
      return new_file_reading if new_file?
      return removed_file_reading if removed_file?
      return untimed_reading unless comparable?
      return "took the same time as it did in the baseline run of this window" unless moved?

      "#{SpecObservation.humanized_duration(change.abs)} " \
        "#{change.negative? ? "faster" : "slower"} than the baseline run of this window"
    end

    private

    def new_file_reading
      return "a file the baseline run did not record, and the newest run reported no timing for it" if latest_seconds.nil?

      "#{anchor_label} of examples, a file the baseline run did not record"
    end

    def removed_file_reading
      return "a file the newest run does not have, and the baseline run reported no timing for it" if previous_seconds.nil?

      "#{baseline_label} of examples in the baseline run and none now"
    end

    def untimed_reading
      return "neither end of this window reported a timing for this file" if previous_seconds.nil? && latest_seconds.nil?
      return "the newest run reported no timing for this file, so there is nothing to compare" if latest_seconds.nil?

      "the baseline run of this window reported no timing for this file, so there is nothing to compare"
    end
  end

  private

  attr_reader :window_growth
end
