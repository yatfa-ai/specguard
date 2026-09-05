# frozen_string_literal: true

# `?q=` read as a substring to find in `github_full_name`, or `nil` for "no ask".
#
# Deliberately its own module rather than a widening of any sibling `Requested*Param`, and one
# module per parameter is the point of the split — the argument `RequestedSpecFileParam` makes for
# itself and every later sibling makes again. The parameters mean different things, are read by
# different surfaces, and one guard answering several of them would make "which shapes does each
# tolerate" a single question nobody asked. What they share is the hazard, and the guard for it is
# the same two lines in the same order.
#
# `is_a?(String)` FIRST, and it is load-bearing rather than defensive: `?q[]=x` parses to an Array
# and `?q[a]=b` to `ActionController::Parameters`. On THIS parameter the hazard is the one the
# spec-file sibling carries — an Array reaching an `ILIKE` would not raise; coerced somewhere it
# would answer a question nobody asked, on a URL anyone can type into the bar. Anything that is not
# a String is treated as no ask, the same answer an absent param gets. All three container shapes
# are pinned, beside the blank string the `.presence` below settles the same way; see
# `spec/support/shared_examples/malformed_search_param.rb`.
#
# `.presence` SECOND, so `?q=` — a browser's unfilled search field — is not an ask. An ask has to
# carry text to find rather than merely be present in the URL: `WHERE github_full_name ILIKE '%%'`
# matches everything and means nothing, which is a longer way of rendering the page the reader
# already had.
#
# No downcasing HERE, and that is a decision rather than an omission. The match is
# case-insensitive in SQL (`ILIKE` at the single call site that reads this, on the index), so
# altering the caller's spelling could not change which rows match — it could only change what the
# page says the reader searched for. The ask is echoed back verbatim, in the filtered-empty state
# and in the search field's value; a reader who typed `Billing` must be told they searched for
# `Billing`, not silently re-spelled. The WILDCARD CHARACTERS are likewise left alone here and
# escaped at the read: `%` and `_` are literal parts of repository names (`org/my_repo`), and
# deciding what a typed `%` means is a property of the match, not of the ask.
module RequestedSearchParam
  extend ActiveSupport::Concern

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — no ask — is the common answer on
  # this page and `||=` would re-read the params on every call. The same idiom, for the same
  # reason, as `RequestedBranchParam#requested_branch`.
  def requested_search
    return @requested_search if defined?(@requested_search)

    raw = params[:q]
    @requested_search = raw.is_a?(String) ? raw.presence : nil
  end
end
