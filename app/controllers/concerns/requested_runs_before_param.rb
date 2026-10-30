# frozen_string_literal: true

# `?runs_before=` read as a TestRun id, or `nil` for "no ask" — the KEYSET CURSOR of the "Recent
# runs" panel on `repositories#show` (SPGD-1984). The panel's widening (`?runs=`, SPGD-1911) stops
# at `RequestedRunsParam::MAX_RUNS`, and at the cap the widen link is suppressed, so on a
# PR-heavy repository the panel used to dead-end: it read "Showing the newest N of M runs." with
# no way forward, and past the newest page the only removal left was destroying the whole
# repository. `?runs_before=<oldest listed id>` names the position the listed window ENDED at, and
# the panel answers with the runs strictly older than it — one bounded page at a time, on the same
# `(created_at DESC, id: DESC)` ordering every other run surface on this page sorts by.
#
# Deliberately its own module and NOT an overload of `?run=` (`RequestedRunIdParam`), even though
# both read a TestRun id under the same shape guard: the two asks mean different things. `?run=`
# RE-ANCHORS the whole page on a row — the panels above describe that run's figures. `?runs_before=`
# positions ONE panel's window and touches no anchor — the page above is the newest run's page as
# always, and only the rows under "Recent runs" moved. One module per parameter, on the reasoning
# every `Requested*Param` sibling gives: a guard loose enough to answer for both would make
# "which shapes does each tolerate" a single question nobody asked, and a divergence either is free
# to make would be a breaking change to the parameter nobody was editing. The two compose rather
# than compete: `?run=` picks the row the page reads, `?runs_before=` picks where this panel's
# window starts, and neither redefines the other.
#
# What it shares with every sibling is the hazard, and the guard is the same lines in the same
# order as `RequestedRunIdParam#requested_run_id`:
#
# * `is_a?(String)` first — `?runs_before[]=5`, `?runs_before[a]=b` and `?runs_before[][a]=b` parse
#   to an Array, to `ActionController::Parameters` and to an Array of them, and none of those is an
#   ask. Treated as no ask, the same answer an absent param gets, rather than reaching a `find_by`
#   that raises — a 500 on a URL anyone can type into the bar.
# * No NUL, second — for the reason every sibling carries: `?runs_before=5%006` parses to a String
#   and answers `.presence` like any other, and the value would never match a row, but the guard
#   keeps the refuse-before-query shape uniform so no parameter on this page is the one that lets a
#   NUL through.
# * `.presence` third, which is what makes `?runs_before=` mean "no ask" rather than "cursor zero".
# * Digits only, fourth — `?runs_before=abc`, `?runs_before=+5`, `?runs_before= 5` (the decode of
#   the `+` spelling too) and `?runs_before=0x10` are all shapes `Integer(...)` would happily
#   coerce, and a coerced ask is a different question from the one typed. An id is a non-negative
#   decimal literal and nothing else; anything else is no ask.
# * ONE `Integer(ask, exception: false)` parse, positive — so `?runs_before=0` and the digits-only
#   forms that parse to zero or less are no ask. Zero matches no row, but the fallback it would
#   trigger is the answer to a MISSED ask, which is a fact about the repository, while a malformed
#   ask is a fact about the URL.
# * Bounded to the bigint ceiling, last — `test_runs.id` is a `bigint` primary key, and an Integer
#   beyond 2^63 - 1 raises `RangeError` at the bind, a 500. Values past the ceiling are no ask,
#   like every other shape this guard refuses.
#
# No validation branch and no 404 on a WELL-FORMED id that matches no row IN THIS REPOSITORY — a
# deleted run, a foreign id, a stale bookmark. A cursor names a POSITION, not a row to read, and
# the caller resolves it through `@repository.test_runs` (`RepositoryDashboard`'s cursor read), so
# a miss simply leaves nothing to continue from: the default newest window renders and NOTHING on
# the page says a cursor was asked — no notice, and no `runs_before` bytes on any link, because
# every downstream reader (the `drill_down_path` carry, the Delete form, the caption) reads the
# RESOLVED cursor, never the raw ask. An id from ANOTHER repository is the same miss, not a leak:
# the resolution reaches `find_by` through `@repository.test_runs`, so a foreign id finds no row
# and can never position this panel on another repository's history.
module RequestedRunsBeforeParam
  # `test_runs.id` is a bigint column, so an ask past this can never match a row — it can only
  # raise at the bind. Guarding here keeps the read's contract "no ask or a plausible id" instead
  # of "no ask, or a 500 on a value the column could never hold".
  MAX_RUN_ID = 2**63 - 1

  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, for the reason every sibling gives: `nil` — no
  # ask — is the common answer on this endpoint and `||=` would re-read the params on every call.
  def requested_runs_before
    return @requested_runs_before if defined?(@requested_runs_before)

    raw = params[:runs_before]
    @requested_runs_before =
      if raw.is_a?(String) && !raw.include?("\u0000") && (ask = raw.presence) && ask.match?(/\A\d+\z/)
        value = Integer(ask, exception: false)
        value if value&.positive? && value <= MAX_RUN_ID
      end
  end
end
