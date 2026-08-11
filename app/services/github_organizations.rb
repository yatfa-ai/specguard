# frozen_string_literal: true

# The GitHub organizations a user can bulk-register from, derived from the repository listing they
# already have.
#
#   GithubOrganizations.from(listing)          # => Array<GithubOrganizations::Org>
#   GithubOrganizations.find(listing, "acme")  # => Org, or nil
#
# ## Why this reads the listing rather than GitHub's org endpoints
#
# `GET /user/repos?affiliation=…organization_member` already returns an organization's repositories,
# each carrying the caller's own `permissions.admin` and its `owner.type`. `GithubApi#repositories`
# states the full argument for reusing it — no `read:org` scope (which every token issued by
# SPGD-354 lacks, and which would therefore break bulk registration for exactly the users who
# already connected), one round trip instead of one per organization plus a page walk inside each,
# and the right set rather than a superset.
#
# ## What "an organization you administer" means here
#
# It means: an organization in which GitHub reports you administer at least one repository.
#
# That is deliberately not the same statement as "you hold the Owner or Admin role in the
# organization" — without `read:org` that role is not readable, and it is also not the predicate the
# feature rests on. Registration is per repository and is gated per repository (`GithubOwnership`),
# so an org role would be neither sufficient (an owner still cannot register a repository GitHub
# says they cannot administer) nor necessary (a repository admin can register that repository
# whatever their org role is). The honest question is the one that decides the outcome.
#
# An organization with nothing to register does not appear at all — the same choice the
# single-repository picker makes for non-admin repositories (`GithubHelper#repository_choices`), and
# for the same reason: offering it is offering a click that can only end in an empty list. What was
# withheld is counted rather than hidden, so a short list is never a mysterious one.
#
# ## Personal repositories are out
#
# Only `owner.type == "Organization"` is grouped. A user's own namespace is not an organization, and
# SPGD-355 is scoped to "choose a GitHub org they administer" — a personal-namespace batch is the
# same machinery pointed at a different set and is left for whoever asks for it, rather than
# smuggled in under a page that says "organization".
class GithubOrganizations
  # One organization and every repository of its the viewer can see.
  #
  # Holds ALL of them, not only the registerable ones, because the two counts are what make the
  # picker honest: `administered` is what may be selected, and `withheld_count` is how the page says
  # why the list is shorter than the organization is.
  #
  # Nothing here is memoised, deliberately: a `Data` instance is frozen, so an `||=` on an ivar
  # raises rather than caching. The lists are tens of entries and are read a handful of times per
  # render, so recomputing is the cheaper of the two mistakes available.
  Org = Data.define(:login, :repos) do
    # Registerable, in the picker's order. Sorted case-insensitively by name so the list reads
    # alphabetically rather than in GitHub's ASCII order, where `Zebra` sorts before `apple`.
    def administered = repos.select(&:admin?).sort_by { |repo| repo.full_name.downcase }

    def administered_count = administered.length

    # Repositories of this organization the viewer can see but cannot administer. Stated as a count
    # rather than listed: naming them is a list of things you may not have, which is noise on a page
    # about what you may register.
    def withheld_count = repos.length - administered_count

    def any_administered? = administered.any?
  end

  class << self
    # Every organization the viewer can register something from, alphabetically.
    #
    # Alphabetical rather than by size: an organization is looked up by name (the reader knows which
    # one they came for), where a repository list is scanned, and "most repositories first" would
    # move the one they want as their access changes.
    def from(listing)
      return [] if listing.nil?

      listing.repos
             .select(&:organization?)
             .group_by(&:owner)
             .map { |login, repos| Org.new(login: login, repos: repos) }
             .select(&:any_administered?)
             .sort_by { |org| org.login.downcase }
    end

    # One organization by login, or `nil` when it is not one this viewer can register from.
    #
    # Case-insensitive because GitHub logins are, and this value arrives from a query string a
    # person can type or a bookmark can carry a differently-cased copy of. `nil` rather than a raise
    # for an unknown login: a stale bookmark and a renamed organization are ordinary ways to arrive
    # here, and the caller renders the chooser again rather than an error page.
    def find(listing, login)
      return nil if login.blank?

      from(listing).find { |org| org.login.casecmp?(login.to_s) }
    end
  end
end
