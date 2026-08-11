# frozen_string_literal: true

# The viewer's own GitHub repositories, and what to say when they cannot be listed.
#
# Extracted from `RepositoriesController` when `BulkRegistrationsController` arrived, because both
# render a picker built from the same listing and both have to answer the same four questions when
# it is not there: is GitHub connected at all, was the token rejected, was the request refused, or is
# GitHub simply down. Those four have four different fixes, and a second controller re-deriving them
# is a second place for them to drift apart — which shows up as one page telling an SSO-blocked user
# to wait while the other tells them to ask their organization.
#
# ## Nothing here is an authorization boundary
#
# This is what the page OFFERS. What may actually be registered is decided at the point of writing,
# by asking GitHub again — `RepositoriesController#save_with_verified_ownership` for one repository,
# `BulkRegistration` for many. So a stale, empty or truncated listing cannot admit anything, and a
# listing failure is a rendered explanation rather than an error page.
module GithubRepositoryListing
  extend ActiveSupport::Concern

  included do
    helper_method :github_listing, :github_listing_error, :github_listing_error_message,
                  :github_authorization_needed?
  end

  private

  # The repositories this user may pick from, straight off GitHub. Memoized and lazy — read by the
  # views that render a picker, and by nothing on the success path, so a registration that verifies
  # costs exactly one GitHub call rather than two.
  def github_listing
    return @github_listing if defined?(@github_listing)

    @github_listing =
      begin
        GithubApi.for(current_user)&.repositories if current_user.github_repository_access?
      rescue GithubApi::Error => e
        Rails.logger.warn("[#{self.class.name}] listing repositories: #{e.class}: #{e.message}")
        @github_listing_error = listing_error_for(e)
        nil
      end
  end

  # The same three-way split the verification path makes, for the same reason: the listing call
  # hits GitHub with the same token and gets the same 403s, so an SSO-blocked user must not be
  # shown "GitHub is not answering right now" — nothing is wrong with GitHub, and waiting will not
  # help. `:token_rejected` and `:scope_too_narrow` are the two the authorize button can fix.
  def listing_error_for(error)
    case error
    when GithubApi::Unauthorized then :token_rejected
    when GithubApi::Forbidden
      GithubOwnership::FORBIDDEN_VERDICTS.fetch(error.reason, :scope_too_narrow)
    else :unavailable
    end
  end

  def github_listing_error
    github_listing
    @github_listing_error
  end

  # The sentence to show when the repository list could not be loaded — reusing the verification
  # path's wording so the two ways of hitting the same GitHub refusal do not explain it differently.
  # Phrased for a whole-page panel, so it is the verdict message with a subject in front of it.
  def github_listing_error_message
    status = github_listing_error
    return nil if status.nil? || status == :unavailable

    "Your repository list #{GithubOwnership::MESSAGES.fetch(status)}"
  end

  # Whether the *fix* on offer is "authorize GitHub" rather than "pick something else". True before
  # the user has ever granted repository access, and again after a token stops working or comes
  # back too narrow to answer with.
  #
  # The ORDER of these three is the whole point, and it is about cost as much as correctness. A
  # verdict, when the request has one, is strictly better evidence than the listing: it comes from
  # the write that was actually attempted, moments ago, with the same token. Reading
  # `github_listing_error` first would force a full `GithubApi#repositories` page walk — up to
  # `MAX_PAGES` round trips — to re-derive an answer the verdict already holds, on the one path
  # (`BulkRegistrationsController#create`) that has just done N inline saves and already paid for
  # that listing under a different memo.
  #
  # This is a no-op for `RepositoriesController`, whose failure path re-renders a picker and so
  # needs the listing regardless.
  def github_authorization_needed?
    return true unless current_user.github_repository_access?
    return github_verdict.reauthorize? if github_verdict

    %i[token_rejected scope_too_narrow].include?(github_listing_error)
  end

  # A verdict this request has already collected about a repository, when there is one — a controller
  # that has just tried to WRITE knows something the listing does not, and it changes the answer
  # above. `nil` here is the honest default for a controller that has only read.
  #
  # `GithubOwnership::Verdict` and `BulkRegistration::Result` both answer `reauthorize?`, so either
  # may be returned; this asks for the capability, not the class.
  def github_verdict = nil
end
