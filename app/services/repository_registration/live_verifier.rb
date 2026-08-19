# frozen_string_literal: true

# ASK GITHUB, NOW, WITH THIS PERSON'S OWN TOKEN — the verifier the web tree passes, and the same
# question `RepositoriesController` has always asked. Nothing about the answer changes here; only
# where the call is written down.
#
# ## `sources:` takes a callable, and that is not fussiness
#
# The controller's `github_sources` is memoized AND LAZY, precisely so a registration that verifies
# costs exactly one GitHub round trip rather than two, and so a rename form submitted UNCHANGED
# costs none at all. A verifier built with `sources: github_sources` would force that read at
# CONSTRUCTION time — before `RepositoryRegistration` has decided whether the name is even changing
# — and the unchanged rename would start paying for a GitHub call, and start failing closed during
# an outage, for a write that changes nothing. Passing `-> { github_sources }` keeps the laziness on
# the controller's side of the seam where it already lived.
#
# A plain `Sources` is accepted too, for callers that genuinely have one in hand.
class RepositoryRegistration
  class LiveVerifier
    def initialize(user:, user_token:, sources: nil)
      @user = user
      @user_token = user_token
      @sources = sources
    end

    def verdict_for(full_name)
      InstallationRepositories.verify(user: @user, user_token: @user_token,
                                      full_name: full_name, sources: resolved_sources)
    end

    private

    # `nil` is a legitimate answer and means "no cached read to share" — `verify` then makes its
    # own. It is NOT the same as a callable that returns nil, which cannot happen:
    # `InstallationRepositories.sources` never returns nil.
    def resolved_sources
      @sources.respond_to?(:call) ? @sources.call : @sources
    end
  end
end
