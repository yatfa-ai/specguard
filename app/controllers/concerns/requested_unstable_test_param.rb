# frozen_string_literal: true

# `?unstable_test=` read as a test description, or `nil` for "no ask".
#
# Deliberately its own module rather than a widening of any sibling `Requested*Param`, and one module
# per parameter is the point of the split — the argument `RequestedSpecFileParam` makes for itself
# and `RequestedRepeatedDescriptionParam` makes again. The parameters mean different things, are read
# by different blocks, and one guard answering several of them would make "which shapes does each
# tolerate" a single question nobody asked. What they share is the hazard, and the guard for it is
# the same two lines in the same order.
#
# Its own module in the sharper case, too, and this is the one worth stating: `?repeated_description=`
# and this parameter are BOTH read as a `spec_observations.name`, so a reader could reasonably ask
# why one module does not serve both. Because they select different POPULATIONS. That one opens one
# run's rows carrying a description; this one opens a WINDOW's. They are free to diverge — a window
# ask could grow a run-count qualifier, a run ask could not — and a single module would make that
# divergence a breaking change to a parameter nobody was editing.
#
# `is_a?(String)` FIRST, and it is not defensive noise: `?unstable_test[]=x` parses to an Array,
# `?unstable_test[a]=b` to `ActionController::Parameters` and `?unstable_test[][a]=b` to an Array of
# them, and none of the three answers `.presence` the way this reads it. This one reaches a
# `where(name: …)` on a plain text column directly, so an Array would not even raise: it would
# quietly become an `IN` list and return the interleaved run sequences of SEVERAL tests under a
# `name` restating one — and at THIS grain that wrong answer is particularly hard to catch by eye,
# because two tests' outcomes shuffled into one list look exactly like the alternation the block
# exists to show. A test that failed in every run and one that passed in every run, merged, are a
# perfect picture of flakiness that nothing in the suite is doing. A silent wrong answer needs the
# guard more than a crash does. Anything that is not a String is treated as no ask, which is the same
# answer an absent param gets — the response is exactly what it was before the parameter existed. All
# three shapes are pinned; see `spec/support/shared_examples/malformed_unstable_test_param.rb`.
#
# `.presence` SECOND, and it is load-bearing here for the reason it is load-bearing one ladder over:
# `spec_observations.name` is NULLABLE — `Ingest::ObservationRecorder#attributes` writes it through
# `presence_of`, so a producer that sends no description stores a nil — and it is precisely why the
# ranking this drills out of counts those rows separately and excludes them from the matching
# (`SpecObservation.unnamed_row_count_in`). A description only reaches that ranking if it HAS a name,
# so the drill-in never legitimately receives a blank; without `.presence` an empty `?unstable_test=`
# would become `WHERE name = ''`, a query for a description no row can carry and so a sequence
# guaranteed to be empty. That is a worse answer than not asking.
#
# No validation branch and no 404: a window that recorded nothing under the description asked for is
# not a malformed request, it is a request whose answer is no rows. A renamed test is the ordinary
# case rather than the exotic one — the project's identity rule is semantic, so a renamed test STARTS
# A NEW HISTORY and every bookmark to the old name goes stale by design — and `UnstableTestRuns` says
# so with an empty sequence naming the description rather than an error page.
module RequestedUnstableTestParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — no ask — is the common answer and
  # `||=` would re-read the params on every call. The same idiom, for the same reason, as
  # `RequestedRepeatedDescriptionParam#requested_repeated_description` and
  # `RequestedBranchParam#requested_branch`.
  def requested_unstable_test
    return @requested_unstable_test if defined?(@requested_unstable_test)

    raw = params[:unstable_test]
    @requested_unstable_test = raw.is_a?(String) ? raw.presence : nil
  end
end
