# frozen_string_literal: true

# The window-comparison scaffolding {SpecDirectoryWindowGrowth} (area COUNT across the branch window)
# and {SpecDirectoryWindowRuntimeGrowth} (area TIME across it) share: the baseline walk, the
# layer-recorded gate, the constructor for the shared state, and the readers and predicates that
# describe the comparison rather than the figure it measures.
#
# A plain module and not an `ActiveSupport::Concern`: the only class-level behaviour is
# {ClassMethods#resolve_window}, wired by {.included}.
#
# What stays in the including classes is exactly what differs between the two: the limit constant,
# the one observation read and how its tuples become rows and states, the `Row` subclass, and the
# predicates that look at the row's own figures (`any_unmoved?` and the runtime-only timing ones).
#
# An including class provides `Row` (so {#rows} are its own) and calls {ClassMethods#resolve_window}
# from its `.for`.
module SpecDirectoryWindowContext
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    # The window prelude. Resolves the shared baseline and decides, WITHOUT any observation read,
    # every outcome the window's loaded rows can decide: the walk's own states (see
    # {WindowBaseline} for the three it can name and the precedence between the two the walk
    # produces — the walk is shared with {LayerWindowGrowth}, so the presenters cannot land on
    # different baselines for one window) and, with a layer asked, the three RECORDED states, decided
    # at run grain because with a layer an empty read can no longer tell "this run recorded nothing"
    # from "this run has no examples of this layer".
    #
    # Otherwise it YIELDS `(baseline, context, narrowed_layer)` to the block, which makes the ONE
    # observation read and returns the finished instance. The read lives in the block so a
    # non-comparable window still issues no observation read and a comparable one issues exactly one.
    #
    # @param runs [RunWindow, Array<TestRun>] the loaded window, read OLDEST first.
    # @param branch [String, nil] the branch every figure is drawn on, for the caption.
    # @param layer [String, Symbol, nil] the declared layer asked for, stringified here; the block
    #   receives the stringified value (nil when none) and must use THAT, not its own raw argument.
    # @yieldparam baseline [WindowBaseline] a baseline that was found.
    # @yieldparam context [Hash] the constructor kwargs shared by every state, baseline included.
    # @yieldparam narrowed_layer [String, nil] the stringified layer.
    # @return [Object] a finished instance, from the walk, the recorded gate or the block.
    def resolve_window(runs, branch:, layer:)
      narrowed_layer = layer&.to_s
      baseline = WindowBaseline.for(runs)
      context = { branch: branch, window_run_count: baseline.window_run_count, anchor_run: baseline.anchor,
                  skipped_unmeasured_count: baseline.skipped_unmeasured_count,
                  skipped_assembled_differently_count: baseline.skipped_assembled_differently_count,
                  layer: narrowed_layer }

      return new(state: baseline.state, **context) unless baseline.found?

      context = context.merge(baseline_run: baseline.run, runs_back: baseline.runs_back)

      if narrowed_layer
        # `layer_counts` is nil exactly when the run recorded no per-example rows (`intent_readings.recorded?`
        # false) — the same fact, read off the value the window's one grouped read primes (SPGD-1829), so the
        # endpoints cost no run-grain aggregate of their own.
        baseline_recorded = !baseline.run.layer_counts.nil?
        anchor_recorded = !baseline.anchor.layer_counts.nil?
        return new(state: :neither_recorded, **context) unless baseline_recorded || anchor_recorded
        return new(state: :baseline_unrecorded, **context) unless baseline_recorded
        return new(state: :anchor_unrecorded, **context) unless anchor_recorded
      end

      yield baseline, context, narrowed_layer
    end
  end

  def initialize(state:, branch: nil, window_run_count: 0, anchor_run: nil, baseline_run: nil,
                 runs_back: 0, skipped_unmeasured_count: 0, skipped_assembled_differently_count: 0,
                 rows: [], directory_count: 0, baseline_recorded_count: 0, anchor_recorded_count: 0,
                 layer: nil)
    @layer = layer&.to_s
    @state = state
    @branch = branch
    @window_run_count = window_run_count
    @anchor_run = anchor_run
    @baseline_run = baseline_run
    @runs_back = runs_back
    @skipped_unmeasured_count = skipped_unmeasured_count
    @skipped_assembled_differently_count = skipped_assembled_differently_count
    @rows = rows
    @directory_count = directory_count
    @baseline_recorded_count = baseline_recorded_count
    @anchor_recorded_count = anchor_recorded_count
  end

  # Which state this is — one comparable, the rest not. A symbol rather than a boolean because the
  # absences are different facts about the window and a reader is owed the one that applies: "every
  # earlier run on this branch reported no tests", "they were all assembled differently from this
  # one" and "the run at the far end recorded no per-example rows" are one blank panel and different
  # things to go and fix.
  attr_reader :state

  # The branch every figure here was drawn on — the trajectory's branch, because a comparison taken
  # across branches is a comparison of different code.
  attr_reader :branch

  # How many runs the window HOLDS. Not how many the comparison spans: see {#covered_run_count}.
  attr_reader :window_run_count

  # The two runs the comparison was actually taken across. The anchor is the newest run of the
  # window; the baseline is the oldest one that could be compared against it, and is nil in the
  # states where the walk found none.
  attr_reader :anchor_run, :baseline_run

  # How many runs back in the window the baseline sits — 29 for a full thirty-run comparison, and
  # less whenever the walk stepped over something. Stated rather than assumed, because it is the
  # difference between the window a reader was promised and the one they were shown.
  attr_reader :runs_back

  # How many runs OLDER than the baseline the walk stepped over, split by which condition rejected
  # them. Split rather than summed because they are two different repairs — a client that stopped
  # reporting totals, and a branch whose sharding changed — and because a bare "4 runs were skipped"
  # is a fact a reader cannot act on.
  attr_reader :skipped_unmeasured_count, :skipped_assembled_differently_count

  # The comparison, largest movement first. Never longer than the limit it was built with, and empty
  # in every non-comparable state.
  attr_reader :rows

  # How many areas the comparison COVERED in total — every directory either run recorded a row in,
  # counted before the `LIMIT` and therefore not `rows.size`. The list is capped, so its own length
  # answers "how many rows am I looking at" and nothing else; a caption built on it would read "the
  # areas that grew most" on a page showing ten of sixty-three.
  attr_reader :directory_count

  # How many per-example rows each end of the comparison recorded in total — the denominators the
  # recorded-rows condition turned on, kept so the caption can state what the panel was measured
  # over. Deliberately NOT `TestRun#total_specs_count`: that column is re-derived by SUM over shard
  # reports and can legitimately differ from the rows the run actually wrote here, and every figure
  # is counted off those rows. The LAYER's own when a layer was asked.
  attr_reader :baseline_recorded_count, :anchor_recorded_count

  # The declared layer this comparison was narrowed to (a `SpecObservation::DECLARED_LAYER_KEYS`
  # member as a String), or nil when it was not — in which case every figure on this object is the
  # un-narrowed one. With a layer, `directory_count` and both recorded counts are the LAYER's, and
  # it is carried in EVERY state, the walk's refusals included, so the contract block can say which
  # layer's comparison was refused.
  attr_reader :layer

  def comparable? = state == :comparable

  def layer? = !layer.nil?

  # A layer was asked and NEITHER end of the window has a single example of it: comparable, and
  # empty. Distinct from every refusal state — both ends recorded per-example rows, the layer just
  # has none in either — so the panel can say "no <layer> examples at either end" instead of a
  # table of nothing.
  def layer_empty? = layer? && comparable? && rows.empty?

  # How many runs of the window the comparison actually SPANS, endpoints included. Equal to
  # `window_run_count` only where the walk stepped over nothing.
  def covered_run_count = runs_back + 1

  # The walk stepped over at least one run, so the comparison spans less of the window than the
  # window holds — the caption's cue to say so rather than let a thirty-run heading stand over a
  # twenty-six-run comparison.
  def shortened? = skipped_count.positive?

  def skipped_count = skipped_unmeasured_count + skipped_assembled_differently_count

  # There are areas the comparison covered that the list does not show.
  def truncated? = directory_count > rows.size

  # At least one listed area's figure actually moved across the window. The ranking is by absolute
  # movement descending, so if any area moved at all the top row is one that did: a false here is a
  # claim about every area the comparison covered.
  def any_movement? = rows.any?(&:moved?)
end
