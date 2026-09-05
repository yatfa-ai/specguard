# frozen_string_literal: true

# A window of {TestRun}s that is ALREADY LOADED and that CARRIES ITS ORIENTATION — the rows, and
# the one fact about them every panel below the load used to leave to a remembered `.reverse`.
#
# == Why the orientation travels with the rows
#
# Five presenters take the thirty-run window and do not agree on what order it is in. Three
# contracts sit behind one parameter shape:
#
# * `SlowestTests` and `SpecDirectoryWindowGrowth` are order-REQUIRED — both take `runs.last` as
#   the run every figure anchors on, and the second walks from index 0 for its baseline, so a
#   window handed in the wrong end first does not raise: it sign-flips every `change` and anchors
#   every ranking on the wrong run, under output that looks perfectly well-formed.
# * `UnstableTests` is order-INDIFFERENT — it reads `runs.map(&:id)` and `runs.size` and nothing
#   else.
# * `UnstableTestRuns` is order-PROPAGATING — the rows it serves follow the handed order exactly,
#   because `SpecObservation.outcome_sequence_in` orders by `array_position` over the ids as
#   handed. It must never be "corrected" to a canonical end.
#
# And the two surfaces that load the window load it in OPPOSITE orders: the web's
# `Repository#suite_size_trajectory` ends `.to_a.reverse` (oldest first), while the API's
# `history_runs` is `Repository#recent_test_runs`, `(created_at, id) DESC` (newest first). Before
# this type, reconciliation lived as a `.reverse` at individual call sites and as `@param` prose —
# `RunWindow` replaces both with an object: the surface that loads the rows states the order it
# has ONCE, at the load, and each presenter asks for the end it needs by name.
#
# == Non-mutating, by construction
#
# The loaded array is FROZEN at construction, and the accessors never reorder anything in place.
# The accessor whose orientation the window already carries hands back that SAME frozen array —
# the one memoized array the surface loaded, which is the point of the window being handed in
# rather than re-queried — and the other accessor hands back a fresh reversed COPY
# (`Array#reverse`, never `reverse!`). Each half of that rule closes one half of the hazard the
# API's `serialized_history` comment used to warn about in prose: an in-place mutation of what a
# consumer is handed (`reverse!`, `sort!`, `<<`, `shift` — the accidents a call site writes while
# "just tidying") now raises FrozenError at the mutating site instead of reaching the memoized
# rows, and the reversed copy is an array nobody else holds, so mutating that cannot reach the
# window either. The memoized rows can no longer be reordered under `serialized_history`'s
# declared `ingested_at_desc,ingest_sequence_desc` contract — the failure mode is a loud
# exception, not a quietly wrong ordering in a response body.
#
# The type is a SECOND net, not a replacement: the request-level examples that fail if an
# orientation is asked for wrongly (`spec/requests/api/v1/repository_slowest_tests_spec.rb`,
# `spec/requests/api/v1/repository_directory_growth_spec.rb`) stay exactly as they are.
class RunWindow
  # Builds the window from rows in OLDEST-FIRST order — run 0 is the earliest run of the branch.
  # This is the web surface's order: `Repository#suite_size_trajectory` ends `.to_a.reverse`.
  def self.oldest_first(runs)
    new(Array(runs), :oldest_first)
  end

  # Builds the window from rows in NEWEST-FIRST order — run 0 is the latest run of the branch.
  # This is the API surface's order: `Repository#recent_test_runs` orders `(created_at, id) DESC`.
  def self.newest_first(runs)
    new(Array(runs), :newest_first)
  end

  # The presenters' seam. A {RunWindow} is taken as the window it is; a bare array is accepted for
  # callers that predate the type (the presenter-level specs hand rows in directly) and read as
  # OLDEST FIRST — the contract `SlowestTests`, `SpecDirectoryWindowGrowth` and `SuiteTrajectory`
  # documented in `@param` prose before the orientation had anywhere to live. `nil` folds to an
  # empty window the way `Array(nil)` always did for `SuiteTrajectory`.
  def self.wrap(runs)
    runs.is_a?(RunWindow) ? runs : new(Array(runs), :oldest_first)
  end

  # The rows in the orientation the window was CONSTRUCTED with — "as handed", never re-sorted.
  # This is the accessor for the order-PROPAGATING reader (`UnstableTestRuns`), whose served rows
  # must follow the caller's window whatever end it starts from, and for the order-INDIFFERENT one
  # (`UnstableTests`), which may not name an end it does not depend on. A reader that needs a
  # SPECIFIC end asks {#oldest_first} or {#newest_first} instead — that is the difference between
  # depending on an order and merely receiving one.
  attr_reader :runs

  # The rows oldest first. The same array object when the window was built oldest first; a fresh
  # reversed copy — the source untouched — when it was not.
  def oldest_first
    @orientation == :oldest_first ? @runs : @runs.reverse
  end

  # The rows newest first. The same array object when the window was built newest first; a fresh
  # reversed copy — the source untouched — when it was not.
  def newest_first
    @orientation == :newest_first ? @runs : @runs.reverse
  end

  # How many runs the window holds — the denominator the presenters word their captions against.
  def size = @runs.size

  # `length` beside `size` so a window reads where the array it replaced was read
  # (`serialized_history_window`'s `returned:` key, for one).
  alias_method :length, :size

  # The emptiness questions a caller asks of the window before it decides anything —
  # `repositories#show` gates four panels on `trajectory_runs.any?`. They are size questions and
  # deliberately NOT orientation questions: asking whether there is anything in the window is not
  # the same act as asking which end it starts from, so they read no orientation.
  def any?(...) = @runs.any?(...)

  def empty? = @runs.empty?

  private

  # Constructed through `.oldest_first` / `.newest_first` / `.wrap`, which exist precisely so the
  # orientation is NAMED at the site that knows it rather than passed as a bare symbol. The rows
  # are frozen here rather than at each accessor: one enforcement point at the only moment the
  # window takes ownership of the array, so every accessor's contract ("the loaded array, or a
  # fresh copy") is guaranteed by the object rather than restated by its readers.
  def initialize(runs, orientation)
    @runs = runs.freeze
    @orientation = orientation
  end
end
