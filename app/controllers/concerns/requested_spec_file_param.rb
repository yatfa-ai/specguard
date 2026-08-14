# frozen_string_literal: true

# `?spec_file=` read as a spec file path, or `nil` for "no ask".
#
# Deliberately its own module rather than a widening of any sibling `Requested*Param`, and one
# module per parameter is the point of the split: the parameters mean different things, are read by
# different surfaces, and one guard answering several of them would make "which shapes does each
# tolerate" a single question nobody asked. What they share is the hazard, and the guard for it is
# the same two lines in the same order.
#
# `is_a?(String)` FIRST, and it is not defensive noise: `?spec_file[]=x` parses to an Array,
# `?spec_file[a]=b` to `ActionController::Parameters` and `?spec_file[][a]=b` to an Array of them,
# and none of the three answers `.presence` the way this reads it — an unguarded
# `params[:spec_file].presence` turns a malformed query string into a 500 on an authenticated GET,
# on a URL anyone can type into the bar. This one reaches a `where(spec_file_path: …)` directly, so
# an Array would not even raise: it would quietly become an `IN` list and answer a question nobody
# asked. Anything that is not a String is treated as no ask, which is the same answer an absent
# param gets — the page renders exactly what it rendered before the parameter existed. All three
# shapes are pinned; see `spec/support/shared_examples/malformed_spec_file_param.rb`.
#
# `.presence` SECOND, which is what makes `?spec_file=` mean "no ask" rather than
# `WHERE spec_file_path = ''`. `spec_file_path` is NOT NULL and is written by
# `Ingest::ObservationRecorder#attributes` falling back to `file_path`, so no row can carry a blank
# — an empty ask would open a drill-down panel guaranteed to be empty, which is a worse answer than
# not opening one.
#
# No validation branch and no 404: a path this run recorded nothing for is not a malformed request,
# it is a request whose answer is no rows. A deleted spec file, a renamed one and a stale bookmark
# are all ordinary ways to arrive here, and `SpecFileExamples` says so with an empty state rather
# than an error page.
module RequestedSpecFileParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — no ask — is the common answer on
  # this page and `||=` would re-read the params on every call. The same idiom, for the same
  # reason, as `RequestedBranchParam#requested_branch`.
  def requested_spec_file
    return @requested_spec_file if defined?(@requested_spec_file)

    raw = params[:spec_file]
    @requested_spec_file = raw.is_a?(String) ? raw.presence : nil
  end
end
