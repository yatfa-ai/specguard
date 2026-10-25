# frozen_string_literal: true

# `?run=` read as a TestRun id, or `nil` for "no ask" — the browser's way to name ONE run of a
# commit the repository holds more than one run of (SPGD-1928).
#
# The gap this parameter closes: `test_runs` has no uniqueness on `commit_sha` (only on
# `(repository_id, ci_run_id)` where a `ci_run_id` was reported), so a CI re-run of one commit is a
# second row, and the page's only existing run ask — `?commit_sha=`, resolved by
# `Repository#latest_test_run_for_commit` — always answers with the NEWEST of them. The older row
# of a re-run pair could not be read from the UI at all: the "Recent runs" row that is not the
# newest same-sha row carried a link byte-identical to its sibling's, and following it opened the
# sibling, with nothing on the page saying so. `?run=<id>` names the row itself, which is the only
# handle that distinguishes two rows printing the same seven characters.
#
# Deliberately its own module and NOT a widening of `?commit_sha=` (`RequestedCommitShaParam`):
# that parameter takes a sha any length or spelling the reporter used, because the column holds
# whatever CI reported; this one takes a row id, where digits-only IS the honest shape and a sha
# would be the malformed one. One module per parameter, on the reasoning every `Requested*Param`
# sibling gives — the two asks mean different things, and a run-id guard loose enough to accept
# shas would be accepting shapes that answer a question nobody asked. They compose rather than
# compete at the read site: `RepositoryDashboard` resolves a run ask FIRST and falls to the sha ask
# only when there is none, which is what makes an anchored-by-id page able to name its row exactly.
#
# What it shares with every sibling is the hazard, and the guard is the same lines in the same
# order as `RequestedRunsParam#requested_runs`:
#
# * `is_a?(String)` first — `?run[]=5`, `?run[a]=b` and `?run[][a]=b` parse to an Array, to
#   `ActionController::Parameters` and to an Array of them, and none of those is an ask. Treated
#   as no ask, the same answer an absent param gets, rather than reaching a `find_by` that raises —
#   a 500 on a URL anyone can type into the bar.
# * No NUL, second — for the reason every sibling carries: `?run=5%006` parses to a String and
#   answers `.presence` like any other, and the value would never match a row, but the guard keeps
#   the refuse-before-query shape uniform so no parameter on this page is the one that lets a NUL
#   through.
# * `.presence` third, which is what makes `?run=` mean "no ask" rather than "run zero".
# * Digits only, fourth — `?run=abc`, `?run=+5`, `?run= 5` and `?run=0x10` are all shapes
#   `Integer(...)` would happily coerce, and a coerced ask is a different question from the one
#   typed. An id is a non-negative decimal literal and nothing else; anything else is no ask.
# * ONE `Integer(ask, exception: false)` parse, positive — so `?run=0` and the digits-only forms
#   that parse to zero or less are no ask. An id of zero matches no row, but the fallback it would
#   trigger is the answer to a MISSED ask, which is a fact about the repository, while a malformed
#   ask is a fact about the URL: the two are kept apart here so the page's fallback notice only
#   ever names an ask that had a legal shape.
# * Bounded to the bigint ceiling, last — `test_runs.id` is a `bigint` primary key, and an Integer
#   beyond 2^63 - 1 raises `RangeError` at the bind, a 500. Values past the ceiling are no ask,
#   like every other shape this guard refuses: there is no row to name and nothing to fall back
#   for that a missing param would not equally have.
#
# No validation branch and no 404 on a WELL-FORMED id that matches nothing. A stale bookmark, a
# deleted run and an id from before a re-ingest are ordinary ways to arrive, and the caller falls
# back the way an unknown sha does — to the newest run, with the page SAYING SO (the fallback
# notice names the ask as `run #<id>`). An id from ANOTHER repository is the same miss, not a
# leak: the resolution reaches `find_by` through `@repository.test_runs`, so a foreign id simply
# finds no row and can never serve another repository's run.
module RequestedRunIdParam
  # `test_runs.id` is a bigint column, so an ask past this can never match a row — it can only
  # raise at the bind. Guarding here keeps the read's contract "no ask or a plausible id" instead
  # of "no ask, or a 500 on a value the column could never hold".
  MAX_RUN_ID = 2**63 - 1

  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, for the reason every sibling gives: `nil` — no
  # ask — is the common answer on this endpoint and `||=` would re-read the params on every call.
  def requested_run_id
    return @requested_run_id if defined?(@requested_run_id)

    raw = params[:run]
    @requested_run_id =
      if raw.is_a?(String) && !raw.include?("\u0000") && (ask = raw.presence) && ask.match?(/\A\d+\z/)
        value = Integer(ask, exception: false)
        value if value&.positive? && value <= MAX_RUN_ID
      end
  end
end
