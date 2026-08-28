# frozen_string_literal: true

# `?limit=` read as an Integer ask for how many rows the run-grain duration rollups should list,
# or `nil` for "no ask" — the block's existing constant then applies, unchanged.
#
# Deliberately its own module rather than a widening of any sibling `Requested*Param`, and one
# module per parameter is the point of the split — the argument `RequestedSpecFileParam` makes for
# itself and every later sibling makes again. The parameters mean different things, are read by
# different blocks, and one guard answering several of them would make "which shapes does each
# tolerate" a single question nobody asked. A numeric ask is no exception: "how many" is not
# "which one" and not "at all", and folding the magnitude into a sibling that reads a key would
# make one module answer questions of two different kinds. What they share is the hazard, and the
# guard against it is the same two lines in the same order.
#
# == ⭐ THE FIRST MAGNITUDE PARAMETER ON THIS ENDPOINT, and why this one alone needs a ceiling
#
# The siblings all name a WHICH (which branch, which area, which file, which description, which
# test), and `?unannotated_examples=` / `?near_duplicates=` name an AT ALL. This one names a HOW
# MANY: it does not open the rows behind a line of a ranking the client had already read, it asks
# the ranking itself to grow. That is a genuinely new axis, and it is the one axis whose value is
# bounded by nothing in the data. A branch is one of the branches the repository has; a file path
# is one of the paths the run wrote. A magnitude is any positive integer a client can type, so
# `?limit=100000` on a 20,000-example suite is an unbounded ask at the design point the roadmap
# names. `MAX_LIMIT` exists for that reason and no sibling needed one: without it the ask stops
# being a widening of a bounded list and becomes an unbounded scan wearing the same parameter.
#
# ABOVE `MAX_LIMIT` THE ASK IS CLAMPED, NOT REJECTED — and the published `limit` field on the API
# reports the clamped figure, so the response says what it did rather than silently serving fewer
# rows than the client counted on. The whole defect this parameter exists to close is a contract
# that states a bound and offers no way to change it; answering an over-large ask with a 400 would
# rebuild that defect one step to the side, and answering it with silently fewer rows would hide
# it. A clamp plus an honest `limit` is the only one of the three that tells the truth.
#
# `is_a?(String)` FIRST, on every sibling's reasoning and not a weaker copy of it:
# `?limit[]=x` parses to an Array, `?limit[a]=b` to `ActionController::Parameters` and
# `?limit[][a]=b` to an Array of them. On THIS parameter the hazard is the silent WRONG SIZE: an
# Array coerced to a string, or a Parameters object leaked into a numeric context, would answer
# with a limit no client asked for — including no limit at all, which silently re-imposes the very
# cap the client was trying to widen past, on a URL the client did not mean to send. Anything that
# is not a String is treated as no ask, which is the same answer an absent param gets — the
# response is exactly what it was before the parameter existed. All three shapes are pinned; see
# `spec/support/shared_examples/malformed_limit_param.rb`.
#
# `.presence` SECOND, so `?limit=` — a browser's unfilled form field, a client building a query
# string off a nil variable — is not an ask. An ask has to carry a magnitude rather than merely be
# present in the URL.
#
# Then ONE parse with no rescue ladder: `Integer(ask, exception: false)` is the only line that
# decides what a numeric string is, and it answers `nil` for every non-integer spelling at once —
# `"abc"`, `"1.5"`, `"0x10"` — rather than a regex that matches today's shapes and misses
# tomorrow's. ZERO and NEGATIVE answers fall to `nil` too: a limit of zero is not a wider list
# and not a narrower one the models have a meaning for, and `ActiveRecord`'s `.limit(nil)` is NO
# limit at all, which is the opposite of what a zero-ask would be read as. A magnitude below one
# is the same no-ask an unparsable one is, on the siblings' rule that there is nothing here for a
# client to correct that a missing param would not equally have.
#
# No validation branch and no 400, on every sibling's rule. And no 404 on the small answer: an ask
# wider than the population is not an error, it is the "All N" state the captions already have a
# branch for.
module RequestedLimitParam
  # The ceiling every widened ask is clamped to. Not a reuse of `SpecObservation::HEAVIEST_FILES_LIMIT`
  # or any other panel constant — those state what a page shows unasked; this states what a client
  # may ask for at most, on any rollup this parameter ever serves. An order of magnitude above the
  # shipped defaults and two orders below the 20,000-example design point, so it widens past every
  # honest "give me more" while bounding the scan an abusive ask could otherwise demand.
  MAX_LIMIT = 200

  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, for the reason every sibling gives: `nil` — no
  # ask — is the common answer on every surface that reads this, and `||=` would re-read the
  # params on every call. The same idiom, for the same reason, as
  # `RequestedSpecFileParam#requested_spec_file`.
  def requested_limit
    return @requested_limit if defined?(@requested_limit)

    raw = params[:limit]
    @requested_limit = if raw.is_a?(String) && (ask = raw.presence)
                         value = Integer(ask, exception: false)
                         value&.positive? ? [value, MAX_LIMIT].min : nil
                       end
  end
end
