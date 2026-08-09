# frozen_string_literal: true

# `?spec_directory=` read as a spec directory path, or `nil` for "no ask".
#
# The third sibling of `RequestedBranchParam` and `RequestedSpecFileParam`, and deliberately its own
# module rather than a widening of either — the argument both of them make, made a third time
# because it does not weaken with repetition. The three parameters mean different things, are read
# by different surfaces and narrow different grains, and one guard answering all three would make
# "which shapes does the branch parameter tolerate", "which shapes does the spec-file parameter
# tolerate" and "which shapes does the spec-directory parameter tolerate" a single question nobody
# asked. What they share is the hazard, and the guard for it is the same two lines in the same
# order.
#
# `is_a?(String)` FIRST, and it is not defensive noise: `?spec_directory[]=x` parses to an Array,
# `?spec_directory[a]=b` to `ActionController::Parameters` and `?spec_directory[][a]=b` to an Array
# of them, and none of the three answers `.presence` the way this reads it. This value reaches an
# EQUALITY comparison in SQL directly — `SpecObservation.files_in_directory` compares it against
# `DIRECTORY_EXPRESSION` — so an Array would not even raise: it would quietly become an `IN` list
# and answer a question nobody asked, under a caption naming one directory. A silent wrong answer
# needs the guard more than a crash does, not less. Anything that is not a String is treated as no
# ask, which is the same answer an absent param gets — the page renders exactly what it rendered
# before the parameter existed. All three shapes are pinned; see
# `spec/support/shared_examples/malformed_spec_directory_param.rb`.
#
# `.presence` SECOND, which is what makes `?spec_directory=` mean "no ask" rather than a comparison
# against the empty string. `DIRECTORY_EXPRESSION` coalesces a path with no separator in it to `.`
# and `spec_file_path` is NOT NULL, so no row's area can be blank — an empty ask would open a
# drill-down panel guaranteed to be empty, which is a worse answer than not opening one.
#
# No validation branch and no 404: an area this run recorded nothing for is not a malformed request,
# it is a request whose answer is no rows. A deleted directory, a renamed one and a stale bookmark
# are all ordinary ways to arrive here, and `SpecDirectoryFiles` says so with an empty state rather
# than an error page.
module RequestedSpecDirectoryParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — no ask — is the common answer on
  # this page and `||=` would re-read the params on every call. The same idiom, for the same
  # reason, as `RequestedBranchParam#requested_branch` and `RequestedSpecFileParam#requested_spec_file`.
  def requested_spec_directory
    return @requested_spec_directory if defined?(@requested_spec_directory)

    raw = params[:spec_directory]
    @requested_spec_directory = raw.is_a?(String) ? raw.presence : nil
  end
end
