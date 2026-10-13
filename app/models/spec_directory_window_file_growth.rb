# frozen_string_literal: true

# Which FILES of ONE area grew or shrank ACROSS THE BRANCH WINDOW — per spec file: the example count
# at the oldest comparable run of the window, the example count at its newest run, and the signed
# movement between them, ranked by how far each moved.
#
# The rung below {SpecDirectoryWindowGrowth}, and the window sibling of {SpecDirectoryFileGrowth}.
# "Areas that grew or shrank over the window" says `spec/models 412 → 459 (+47)` and, like its
# last-push twin, could not say which FILES did it; the only file-grain object compared the LAST PUSH
# alone, where a file that gained forty tests over thirty pushes reads about zero per push.
#
# == A composition, not a new query
#
# {SpecObservation.file_growth_between} takes ANY two runs (it uses only their ids); handed the
# window's anchor and baseline instead of a run and its predecessor it is the window comparison —
# the same move {SpecDirectoryWindowRuntimeGrowth} makes for {SpecObservation.directory_runtime_growth_between}.
# No new SQL, no migration, and no change to the read, to {SpecDirectoryWindowGrowth} or to
# {WindowBaseline}.
#
# == The comparability gate is the PARENT'S verdict, not a second spelling of it
#
# `.for` takes the already-built {SpecDirectoryWindowGrowth} and refuses to read anything the moment
# it is not comparable — in all EIGHT of its states (the walk's four, the recorded arms, and the
# layer-recorded ones), with ZERO observation reads. It carries the parent's baseline, anchor,
# `runs_back` and window counts verbatim rather than re-deriving the baseline, so the panel, the API
# block and the area panel above them can only name one baseline commit for one window.
#
# The RECORDED states are likewise the parent's run-grain verdict and are not re-derived from this
# area's totals: an area only the anchor recorded has zero baseline-side rows, which would spell
# `baseline_unrecorded` identically and mean something else ("this area is new", not "the baseline
# run recorded nothing"). With `layer`, a layer empty at one end reads as `new_file?` /
# `removed_file?` rows, never as an unrecorded state.
#
# == It compares TWO ENDPOINTS. It is not a series, and it says so
#
# A file that gained forty examples in run 12 and lost forty in run 25 reads `±0` here, and a file
# that was MOVED reads as one file removed beside one new. It counts rows per file in each of two
# runs and subtracts; no example is paired with another across the boundary.
#
# == One object, so the panel and the API cannot disagree
#
# Every figure comes back from the one grouped aggregate that returned the rows (windows counted
# before the `LIMIT`); the web partial and `RepositoryGrowthSerializer` both read this object.
class SpecDirectoryWindowFileGrowth
  # Builds the comparison for one area, or the parent's stated refusal.
  #
  # @param path [String] the asked area, as asked.
  # @param window_growth [SpecDirectoryWindowGrowth] the already-built parent for this window.
  # @param limit [Integer] the cap on listed files; `file_count` is counted before it.
  # @param layer [String, Symbol, nil] ONE declared layer to narrow to — the parent's layer, passed
  #   through to the read.
  def self.for(path, window_growth:, limit: SpecObservation::SPEC_DIRECTORY_FILE_GROWTH_LIMIT, layer: nil)
    layer = layer&.to_s
    return new(path: path, window_growth: window_growth, layer: layer) unless window_growth.comparable?

    tuples = SpecObservation.file_growth_between(window_growth.anchor_run, window_growth.baseline_run, path,
                                                 limit: limit, layer: layer)
    from_tuples(path, window_growth, tuples, layer)
  end

  # The window totals ride on every row and are identical on all of them, so they are read off the
  # first; `to_i` on the nil of an empty read, where zero files and zero rows on both sides is the
  # honest count ({#recorded?} false).
  def self.from_tuples(path, window_growth, tuples, layer)
    rows = tuples.map do |file_path, baseline, anchor, *|
      Row.new(path: file_path, previous_count: baseline.to_i, latest_count: anchor.to_i)
    end

    _path, _baseline, _anchor, file_count, baseline_recorded, anchor_recorded = tuples.first

    new(path: path, window_growth: window_growth, rows: rows, file_count: file_count.to_i,
        baseline_recorded_count: baseline_recorded.to_i, anchor_recorded_count: anchor_recorded.to_i,
        layer: layer)
  end
  private_class_method :from_tuples

  def initialize(path:, window_growth:, rows: [], file_count: 0, baseline_recorded_count: 0,
                 anchor_recorded_count: 0, layer: nil)
    @path = path
    @window_growth = window_growth
    @rows = rows
    @file_count = file_count
    @baseline_recorded_count = baseline_recorded_count
    @anchor_recorded_count = anchor_recorded_count
    @layer = layer&.to_s
  end

  # The area that was asked for, as it was asked for. Held even when nothing came back.
  attr_reader :path

  # The comparison, largest movement first. Never longer than the limit, empty in every
  # non-comparable state.
  attr_reader :rows

  # How many spec files the comparison COVERED in this area, counted before the `LIMIT` and
  # therefore not `rows.size`.
  attr_reader :file_count

  # How many per-example rows each end recorded IN THIS AREA — deliberately not the parent's
  # identically-named whole-run figures.
  attr_reader :baseline_recorded_count, :anchor_recorded_count

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

  # At least one listed file's count actually moved. The ranking is by absolute movement descending,
  # so a false here is a claim about every file the comparison covered.
  def any_movement? = rows.any?(&:moved?)

  # At least one LISTED file did not move.
  def any_unmoved? = rows.any? { |row| !row.moved? }

  # One spec file's movement across the window — {SpecDirectoryFileGrowth::Row}, with every
  # sentence that names WHAT the movement was measured against re-worded: "than the previous run on
  # this branch" is false of a figure taken across a window. `previous_count`/`latest_count` keep the
  # parent's names and read as the BASELINE and ANCHOR ends.
  class Row < SpecDirectoryFileGrowth::Row
    def baseline_count_label = previous_count_label

    def anchor_count_label = latest_count_label

    def change_reading
      return "#{example_phrase(latest_count)}, a file the baseline run did not record" if new_file?
      return "#{example_phrase(previous_count)} in the baseline run and none now" if removed_file?
      return "unchanged since the baseline run of this window" unless moved?

      "#{example_phrase(change.abs)} #{change.negative? ? "fewer" : "more"} " \
        "than the baseline run of this window"
    end
  end

  private

  attr_reader :window_growth
end
