# frozen_string_literal: true

# WHERE A BRANCH WINDOW'S COMPARISON LANDS — the anchor (the newest run of the window), the baseline
# (the oldest run of it that can soundly be compared against the anchor), and why there is none when
# there is none. ONE walk, shared by every presenter that compares the TWO ENDPOINTS of the
# `?branch=` window: {SpecDirectoryWindowGrowth} (area counts) and {LayerWindowGrowth} (the
# declared-layer mix). Two spellings of "which run is the baseline" is how `directory_growth` and
# `layer_growth` would come to name different runs for the same window; this is the one spelling.
#
# == The walk
#
# From the OLDEST end, so the comparison spans as much of the window as is sound. Each step is two
# in-memory predicates over a row already loaded; nothing here touches the database:
#
# * `TestRun#suite_size_measured?` on the candidate — a run that reported zero tests has a count and
#   not a measurement. Counted in `skipped_unmeasured_count`.
# * `TestRun#assembled_like?` across anchor and candidate — the Overview delta's own predicate,
#   reused rather than re-spelled. Counted in `skipped_assembled_differently_count`.
#
# The first survivor is the baseline and `runs_back` is how far from the anchor it sits. Runs NEWER
# than the baseline are never examined, so the skip counts say how many OLDER runs were stepped over.
#
# == States
#
# `:anchor_unmeasured` and `:no_earlier_run` are decided from the anchor and the window's size alone
# (no walk, skip counts 0). Otherwise `:found`, or — when the walk ran the window out — whichever
# condition did it: `:no_comparable_composition` takes precedence over `:no_measured_baseline`
# because reaching it means the walk DID find runs that measured a suite, so "no earlier run
# measured anything" would be false of this window.
class WindowBaseline
  # @param runs [RunWindow, Array<TestRun>] the loaded window; read OLDEST first.
  def self.for(runs)
    window = RunWindow.wrap(runs)
    window_runs = window.oldest_first
    anchor = window_runs.last

    return new(state: :anchor_unmeasured, window: window, anchor: anchor) unless anchor&.suite_size_measured?
    return new(state: :no_earlier_run, window: window, anchor: anchor) if window.size < 2

    walk(window, window_runs, anchor)
  end

  def self.walk(window, window_runs, anchor)
    unmeasured = 0
    mismatched = 0
    index = nil

    window_runs[0..-2].each_with_index do |run, position|
      next unmeasured += 1 unless run.suite_size_measured?
      next mismatched += 1 unless anchor.assembled_like?(run)

      index = position
      break
    end

    counts = { skipped_unmeasured_count: unmeasured, skipped_assembled_differently_count: mismatched }

    if index.nil?
      return new(state: mismatched.positive? ? :no_comparable_composition : :no_measured_baseline,
                 window: window, anchor: anchor, **counts)
    end

    new(state: :found, window: window, anchor: anchor, run: window_runs[index],
        runs_back: window_runs.size - 1 - index, **counts)
  end
  private_class_method :walk

  def initialize(state:, window:, anchor:, run: nil, runs_back: 0, skipped_unmeasured_count: 0,
                 skipped_assembled_differently_count: 0)
    @state = state
    @window = window
    @anchor = anchor
    @run = run
    @runs_back = runs_back
    @skipped_unmeasured_count = skipped_unmeasured_count
    @skipped_assembled_differently_count = skipped_assembled_differently_count
  end

  attr_reader :state, :window, :anchor, :run, :runs_back, :skipped_unmeasured_count,
              :skipped_assembled_differently_count

  def found? = state == :found

  def window_run_count = window.size
end
