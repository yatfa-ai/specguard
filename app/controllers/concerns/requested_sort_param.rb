# frozen_string_literal: true

# `?sort=` read as an ordering ask for the repositories index — `stale`, last-ingested recency
# with never-ingested first — or `nil` for "no ask" (the page's default `github_full_name` order).
#
# Deliberately its own module rather than a widening of any sibling `Requested*Param`, and one
# module per parameter is the point of the split — the argument `RequestedSpecFileParam` makes for
# itself and every later sibling makes again. What they share is the hazard, not the subject.
#
# `is_a?(String)` FIRST, on every sibling's reasoning: `?sort[]=x` parses to an Array and
# `?sort[a]=b` to `ActionController::Parameters`, and neither is an ordering. Anything that is not
# a String is treated as no ask — the same answer an absent param gets. All three shapes are
# pinned; see `spec/support/shared_examples/malformed_sort_param.rb`.
#
# `.presence` SECOND, so `?sort=` — a select submitted at its default — is not an ask.
#
# THEN THE VOCABULARY CLAMP, on `RequestedRoleParam`'s reasoning exactly: a String that names no
# ordering (`?sort=newest`, `?sort=name`, a typo) reads as no ask, which hands the reader the
# default order rather than an error. THE DEFAULT IS NOT A VOCABULARY WORD, deliberately: the
# page's name order is what an absent parameter means, and `nil` already says that. Admitting
# `name` as a spelling of the default would make two words for one behavior and invite a third
# the next time someone wants "name, descending" — an ordering the page does not offer.
#
# `SORTS` is frozen and lives here for the same reason `RequestedRoleParam::ROLES` does: it is
# the READ's vocabulary, and the select that emits `?sort=` is populated from the same words.
module RequestedSortParam
  extend ActiveSupport::Concern

  # The orderings the page offers beyond its default. Each word names ONE ordering and the method
  # that applies it, so adding one is adding both — there is no word for "the default", which nil
  # already means.
  SORTS = %w[stale].freeze

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — no ask — is the common answer on
  # this page and `||=` would re-read the params on every call. The same idiom, for the same
  # reason, as `RequestedBranchParam#requested_branch`.
  def requested_sort
    return @requested_sort if defined?(@requested_sort)

    raw = params[:sort]
    @requested_sort = if raw.is_a?(String) && (ask = raw.presence)
                        SORTS.include?(ask) ? ask : nil
                      end
  end
end
