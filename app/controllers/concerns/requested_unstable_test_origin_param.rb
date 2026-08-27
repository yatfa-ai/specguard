# frozen_string_literal: true

# `?unstable_test_from=` read as the panel a test was opened FROM, or `nil` for "not said".
#
# A QUALIFIER of `?unstable_test=` rather than an ask of its own, and that is the one thing to know
# about it: it opens no panel, narrows no population and is read by exactly one control — the
# "Close test" button on `_unstable_test_runs.html.erb`. Every sibling `Requested*Param` names a
# panel's subject; this one names a gesture's origin.
#
# WHY IT HAS TO BE IN THE URL. "This test, run by run" is reached by a full page load, so by the
# time the Close control renders, the panel the reader left is not a fact anything on the server
# still holds. The only channel from the gesture to the control is the address it navigated to.
#
# WHY IT HAS TO EXIST AT ALL. That control used to anchor back at a hardcoded `#unstable-tests`,
# which was correct while the flakiness ranking was the ONLY way in. "Slowest tests" is now a second
# way in, and it ranks wall clocks with no reference to stability — so its ordinary row is a test
# the flakiness ranking does not list. A reader who opened such a test and closed it was returned to
# a panel that, by construction, could not contain the row they came from, thousands of pixels from
# the one that could. A static anchor cannot represent two origins; this is what makes it dynamic.
#
# AN ALLOW-LIST, and it is not defensive noise: this value becomes a URL FRAGMENT. Echoing an
# arbitrary string there cannot script anything — `repository_path` escapes it — but it would send
# the reader to an anchor no panel answers to, which is a silent wrong answer rather than a loud
# one. Only the ids of the two panels that OFFER the gesture are honoured, so the set of legal
# values is the set of real entry points and adding a third is a deliberate edit here.
#
# `is_a?(String)` FIRST, for the reason `RequestedUnstableTestParam` gives at greater length:
# `?unstable_test_from[]=x` parses to an Array and `?unstable_test_from[a]=b` to
# `ActionController::Parameters`, neither of which answers `include?` against the list below the way
# this reads it. Anything that is not a String is treated as not said.
#
# NOT SAID IS THE ORDINARY ANSWER, not an error. A bookmark, a typed URL and every link written
# before this existed carry no origin, and the control falls back to the ranking it always anchored
# at — so the older entry point behaves exactly as it did. There is no validation branch and no 404:
# the worst an unrecognised value can cost is the fallback, which is the answer that shipped for
# months.
module RequestedUnstableTestOriginParam
  extend ActiveSupport::Concern

  # The panels that offer the gesture, by the `id` each renders under, and so the only values this
  # parameter can take. Named rather than counted, and the two are deliberately spelled as the DOM
  # ids they are: the value is consumed as an anchor, so a name that drifted from its panel's id
  # would fail as a scroll target rather than as a lookup.
  PANELS = ["unstable-tests", "slowest-examples"].freeze

  private

  # Memoized with `defined?` rather than `||=`, because `nil` — not said — is the common answer and
  # `||=` would re-read the params on every call. The same idiom, for the same reason, as
  # `RequestedUnstableTestParam#requested_unstable_test`.
  def requested_unstable_test_origin
    return @requested_unstable_test_origin if defined?(@requested_unstable_test_origin)

    raw = params[:unstable_test_from]
    @requested_unstable_test_origin = raw if raw.is_a?(String) && PANELS.include?(raw)
  end
end
