# frozen_string_literal: true

# The GitHub organizations a user can bulk-register from, derived from the repository listing they
# already have.
#
#   GithubOrganizations.from(listing)          # => Array<GithubOrganizations::Org>
#   GithubOrganizations.find(listing, "acme")  # => Org, or nil
#
# ## Why this reads the listing rather than GitHub's org endpoints
#
# The listing is already exactly the right set. `GET /installation/repositories` returns the
# repositories somebody who administers them deliberately handed to SpecGuard, each carrying its
# `owner.type`, so grouping it by owner yields the organizations this viewer can register from —
# for one round trip, and without the App needing any permission beyond the Metadata it has.
#
# `GET /orgs/:org/repos` would be worse on every axis that matters here: another endpoint, one call
# per organization plus a page walk inside each, and a SUPERSET rather than the right set — it lists
# repositories the App was never installed on, which are precisely the ones registration refuses.
#
# ## What "an organization you can register from" means here
#
# It means: an organization with at least one repository in this viewer's installation. That is not
# a claim about anyone's org role, and it deliberately is not — an org owner still cannot register a
# repository nobody installed the App on, and somebody who administers exactly one repository can
# register exactly that one. The honest question is the one that decides the outcome, and here it
# is answered by the installation itself.
#
# An organization with nothing in the installation does not appear at all, because it cannot: it
# contributes no repositories to group. There is no "withheld" count any more and its absence is the
# point — the OAuth listing returned everything the user could see and had to explain why most of it
# was not on offer, where an installation contains only what was chosen.
#
# ## Personal repositories are out
#
# Only `owner.type == "Organization"` is grouped. A user's own namespace is not an organization, and
# SPGD-355 is scoped to "choose a GitHub org they administer" — a personal-namespace batch is the
# same machinery pointed at a different set and is left for whoever asks for it, rather than
# smuggled in under a page that says "organization".
class GithubOrganizations
  # One organization and the repositories of its that are in this viewer's installation — which is
  # to say, all of the ones they can register.
  #
  # Nothing here is memoised, deliberately: a `Data` instance is frozen, so an `||=` on an ivar
  # raises rather than caching. The lists are tens of entries and are read a handful of times per
  # render, so recomputing is the cheaper of the two mistakes available.
  Org = Data.define(:login, :repos) do
    def count = repos.length
    def any? = repos.any?
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
