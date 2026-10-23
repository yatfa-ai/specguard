# frozen_string_literal: true

# `?runs=` read as an Integer ask for how many rows the "Recent runs" panel on `repositories#show`
# should list, or `nil` for "no ask" — the panel's default then applies, unchanged.
#
# Deliberately its own module and NOT a reuse of `?limit=` (`RequestedLimitParam`): that parameter
# widens the run-grain duration rollups, and one parameter that also resized the run history would
# make a single link widen two unrelated panels. One module per parameter, on the same reasoning
# every `Requested*Param` sibling gives. What they share is the hazard, and the guard is the same
# lines in the same order as `RequestedLimitParam#requested_limit`:
#
# * `is_a?(String)` first — `?runs[]=x`, `?runs[a]=b` and `?runs[][a]=b` parse to an Array, to
#   `ActionController::Parameters` and to an Array of them, and none of those is an ask. They are
#   treated as no ask, the same answer an absent param gets, rather than coerced to a size.
# * `.presence` second, so an unfilled form field (`?runs=`) is not an ask.
# * ONE `Integer(ask, exception: false)` parse; zero and negative answers fall to no ask too,
#   because `.limit(nil)` in ActiveRecord is NO limit — the opposite of what a zero would mean.
#
# ABOVE `MAX_RUNS` THE ASK IS CLAMPED, NOT REJECTED: the history is append-only and unbounded, so
# an uncapped magnitude would be an unbounded scan wearing a display parameter. The panel then
# renders the clamped figure and says how many it is showing, so the clamp is never silent.
module RequestedRunsParam
  # How many runs the panel lists when nobody asked for more. The single home of the default:
  # `Repository#recent_test_runs` takes it as a keyword and the view's "Back to the newest N"
  # link reads it from here.
  DEFAULT_RUNS = 10

  # The most a client may ask the panel to list. Several times the default, so it reaches well
  # past a junk shard row older than the newest page, and small enough that the panel stays a
  # panel: the per-row work is one grouped shard-count query whatever the row count.
  MAX_RUNS = 50

  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` for the reason every sibling gives: `nil` is the common answer.
  def requested_runs
    return @requested_runs if defined?(@requested_runs)

    raw = params[:runs]
    @requested_runs = if raw.is_a?(String) && (ask = raw.presence)
                        value = Integer(ask, exception: false)
                        value&.positive? ? [value, MAX_RUNS].min : nil
                      end
  end
end
