# frozen_string_literal: true

# `?repeated_description=` read as a test description, or `nil` for "no ask".
#
# The third sibling of `RequestedBranchParam` and `RequestedSpecFileParam`, and deliberately its own
# module rather than a widening of either, for the reason `RequestedSpecFileParam` gives about the
# first: the three parameters mean different things, are read by different panels, and one guard
# answering all of them would make "which shapes does `?branch=` tolerate", "which shapes does
# `?spec_file=` tolerate" and "which shapes does `?repeated_description=` tolerate" a single
# question nobody asked. What they share is the hazard, and the guard for it is the same two lines
# in the same order.
#
# `is_a?(String)` FIRST, and it is not defensive noise: `?repeated_description[]=x` parses to an
# Array, `?repeated_description[a]=b` to `ActionController::Parameters` and
# `?repeated_description[][a]=b` to an Array of them, and none of the three answers `.presence` the
# way this reads it — an unguarded `params[:repeated_description].presence` turns a malformed query
# string into a 500 on an authenticated GET, on a URL anyone can type into the bar. This one reaches
# a `where(name: …)` on a plain text column directly, so an Array would not even raise: it would
# quietly become an `IN` list and answer about several descriptions under a caption naming one. A
# silent wrong answer needs the guard more than a crash does. Anything that is not a String is
# treated as no ask, which is the same answer an absent param gets — the page renders exactly what
# it rendered before the parameter existed. All three shapes are pinned; see
# `spec/support/shared_examples/malformed_repeated_description_param.rb`.
#
# `.presence` SECOND, and it is load-bearing at THIS grain in a way it is not at the file one.
# `spec_observations.name` is NULLABLE — `Ingest::ObservationRecorder#attributes` writes it through
# `presence_of`, so a producer that sends no description stores a nil — and it is precisely why the
# ranking this drills out of excludes unnamed rows in SQL (`RepeatedDescriptions#named?`). A group
# therefore only reaches the ranking if it HAS a name, so the drill-down never legitimately receives
# a blank; without `.presence` an empty `?repeated_description=` would become `WHERE name = ''`,
# which is a query for a description no row can carry and so a drill-down panel guaranteed to be
# empty. That is a worse answer than not opening one.
#
# No validation branch and no 404: a description this run recorded nothing for is not a malformed
# request, it is a request whose answer is no rows. A renamed test, a description edited since and a
# stale bookmark are all ordinary ways to arrive here, and `RepeatedDescriptionExamples` says so
# with an empty state naming the description rather than an error page.
module RequestedRepeatedDescriptionParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — no ask — is the common answer on
  # this page and `||=` would re-read the params on every call. The same idiom, for the same reason,
  # as `RequestedSpecFileParam#requested_spec_file` and `RequestedBranchParam#requested_branch`.
  def requested_repeated_description
    return @requested_repeated_description if defined?(@requested_repeated_description)

    raw = params[:repeated_description]
    @requested_repeated_description = raw.is_a?(String) ? raw.presence : nil
  end
end
