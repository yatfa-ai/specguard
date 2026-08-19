# frozen_string_literal: true

# The viewer's connected GitHub repositories, and what to say when they cannot be listed.
#
# Extracted from `RepositoriesController` when `BulkRegistrationsController` arrived, because both
# render a picker built from the same source and both have to answer the same questions when it is
# not there: has this user installed the App at all, did GitHub refuse, or is GitHub simply down.
# Those have different fixes, and a second controller re-deriving them is a second place for them
# to drift apart.
#
# ## Nothing here is an authorization boundary
#
# This is what the page OFFERS. What may actually be registered is decided at the point of writing,
# by asking GitHub again — `RepositoriesController#save_with_verified_ownership` for one repository,
# `BulkRegistration` for many. So a stale, empty or truncated listing cannot admit anything, and a
# listing failure is a rendered explanation rather than an error page.
module GithubRepositoryListing
  extend ActiveSupport::Concern

  # Every read here is made with the viewer's own GitHub credential, which lives in their session.
  # A controller that lists repositories therefore always has both.
  include GithubUserSession

  included do
    helper_method :github_listing, :github_listing_error, :github_listing_error_message,
                  :github_listing_incomplete?, :github_installation_needed?,
                  :github_visible_listing, :github_withheld_count
  end

  private

  # Everything the viewer's installations could be read as. Memoized and lazy — read by the views
  # that render a picker, and by nothing on the success path, so a registration that verifies costs
  # exactly one trip to GitHub rather than two.
  def github_sources
    @github_sources ||= InstallationRepositories.sources(current_user, user_token: github_user_token)
  end

  # The repositories this user may pick from — the ones they administer — as the plain
  # `GithubApi::Listing` every view and helper takes, or `nil` when there is nothing to pick from
  # and a sentence is owed instead.
  #
  # `nil` covers three situations that read differently and are told apart by `github_listing_error`
  # and `github_installation_needed?`: GitHub refused or could not be reached, this session holds no
  # credential to ask with, and the user has not installed the App. It does NOT cover "installed,
  # and administers nothing in it" — that is an empty listing rather than a missing one, and the
  # picker says so in its own words.
  def github_listing
    return nil unless github_sources.installed?
    return nil if github_sources.registrable.empty? && github_sources.error

    github_sources.listing
  end

  # Everything the viewer can SEE across their installations, administered or not — what
  # `github_listing` narrows before it hands the picker anything. It is NOT a second source a
  # picker may be built from: every repository in it that is missing from `github_listing` is one
  # registration would refuse.
  #
  # It exists because the difference between the two is the only honest account a page can give of
  # its own length. An organization member with view access to thirty repositories and admin on
  # three is the ordinary case, not the exotic one, and a page that shows them three and says
  # nothing is a page they will read as broken.
  #
  # `nil` in exactly the situations `github_listing` is nil, so a caller cannot accidentally use it
  # to render something on a page that has nothing to render.
  def github_visible_listing
    return nil if github_listing.nil?

    github_sources.visible_listing
  end

  # How many repositories the viewer can reach but may not register, for the sentence that says so.
  # Zero — not nil — when there is nothing to explain, including when there is no listing at all.
  def github_withheld_count
    return 0 if github_listing.nil?

    github_sources.withheld_count
  end

  # The verdict status that stopped the listing being the whole story, or `nil` when nothing did.
  # The same statuses the verification path uses, because it is the same GitHub answering the same
  # credential — an installation refused for one is refused for both.
  def github_listing_error = github_sources.error

  # The sentence to show when the repository list could not be loaded — reusing the verification
  # path's wording so the two ways of hitting the same GitHub refusal do not explain it differently.
  # Phrased for a whole-page panel, so it is the verdict message with a subject in front of it.
  #
  # `nil` for `:unavailable`, which is the genuine outage the caller renders "try again shortly"
  # for; for `:not_authorized`, which the reconnect button answers rather than a sentence; and for
  # no error at all.
  def github_listing_error_message
    status = github_listing_error
    return nil if status.nil? || status == :unavailable || status == :not_authorized

    "Your repository list #{InstallationRepositories::MESSAGES.fetch(status)}"
  end

  # Whether a list IS being shown and is nevertheless known to be short — one of the viewer's
  # installations answered and another did not. Distinct from `github_listing.nil?`, which is the
  # case where there is nothing to show at all, and it needs its own answer: the picker renders,
  # everything in it is genuinely registerable, and a repository the reader came for may still be
  # missing for a reason that is ours rather than GitHub's.
  #
  # Saying so is the same rule the truncation note follows. A picker that silently omits things is
  # a picker people stop trusting, and "my repository is not in the list" is indistinguishable from
  # "SpecGuard is broken" unless the page says which it is.
  def github_listing_incomplete? = github_sources.error.present? && github_sources.registrable.any?

  # Whether the *fix* on offer is "install the SpecGuard GitHub App" rather than "pick something
  # else". True before the user has installed it at all — and only then, because everything after
  # that is a question of which repositories are in the installation, which is fixed on GitHub's
  # configure page rather than by installing again.
  #
  # A verdict this request already collected wins over the stored fact, for the reason it always
  # did: it comes from the write that was actually attempted, moments ago, against the same
  # installations.
  #
  # Asked of `User#github_installed?` rather than of `github_sources`, which would answer the same
  # thing: this is one `EXISTS` against our own table, where reading the sources means a GitHub page
  # walk per installation. That matters because the view asks this FIRST — a user with nothing
  # installed gets the button without SpecGuard having called GitHub at all, which is the right cost
  # for a question our own table can settle.
  def github_installation_needed?
    return github_verdict.install? if github_verdict

    !current_user&.github_installed?
  end

  # Whether the fix on offer is "reconnect to GitHub" — the App is installed and this session simply
  # has no credential to read it with. Overrides `GithubUserSession`'s plain reading to add the same
  # verdict seam `github_installation_needed?` uses, and for the same reason: a write that was
  # actually attempted moments ago knows something the session state does not.
  def github_authorization_needed?
    return github_verdict.authorize? if github_verdict

    super
  end

  # A verdict this request has already collected about a repository, when there is one — a controller
  # that has just tried to WRITE knows something the listing does not, and it changes the answer
  # above. `nil` here is the honest default for a controller that has only read.
  #
  # `InstallationRepositories::Verdict` and `BulkRegistration::Result` both answer `install?`, so
  # either may be returned; this asks for the capability, not the class.
  def github_verdict = nil
end
