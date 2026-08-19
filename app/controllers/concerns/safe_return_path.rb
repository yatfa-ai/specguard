# frozen_string_literal: true

# Where to send someone back to after a round trip through GitHub.
#
# Both flows that leave this site need it and neither may trust it: OmniAuth stashes the sign-in
# origin in `omniauth.origin`, and the App installation flow round-trips its own in GitHub's `state`
# parameter. Either way the value started life as something a user controls, and the last hop of an
# authorization flow is the single most attractive open redirect an app has — a link that ends
# "…&state=https://evil.example" is one that arrives on this site's domain and leaves it again.
#
# So a return path is admitted only as a path ON THIS SITE, and anything else is discarded rather
# than corrected. Discarding is deliberate: a value we cannot vouch for is not one to repair into
# something adjacent, and the fallback is always somewhere the user was going anyway.
module SafeReturnPath
  extend ActiveSupport::Concern

  private

  # `candidate` when it is a relative path on this site, `fallback` otherwise.
  #
  # The two rejected shapes are the ones that look local and are not: `//evil.example` is a
  # protocol-relative URL that a browser resolves against the current scheme, and `/\evil.example`
  # is the same trick with the slash a few user agents normalise. An absolute URL fails the leading
  # `/` test outright.
  def safe_return_path(candidate, fallback:)
    path = candidate.to_s

    return fallback unless path.start_with?("/")
    return fallback if path.start_with?("//", "/\\")

    path
  end
end
