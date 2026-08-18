# frozen_string_literal: true

# The GitHub organizations a user can bulk-register from, derived from the repository listing they
# already have.
#
#   GithubOrganizations.from(listing)          # => Array<GithubOrganizations::Org>
#   GithubOrganizations.find(listing, "acme")  # => Org, or nil
#
# The listing it takes is the VISIBLE one — everything the viewer can reach across their
# installations, administered or not (`InstallationRepositories::Sources#visible_listing`) — and not
# the narrowed one the single-repository picker is built from. It needs both halves: what may be
# registered is what it offers, and what may not is what it has to account for.
#
# ## Why this reads the listing rather than GitHub's org endpoints
#
# The listing is already the right raw material, because `InstallationRepositories` has narrowed it
# to this viewer's installations before this sees it, and each repository carries both its
# `owner.type` and this viewer's own `permissions.admin`. So grouping by owner yields the
# organizations this viewer can register from AND the count of what is being withheld from them —
# for no extra round trip, and without the App needing any permission beyond the Metadata it has.
#
# `GET /orgs/:org/repos` would be worse on every axis that matters here: another endpoint, one call
# per organization plus a page walk inside each, and a SUPERSET rather than the right set — it lists
# repositories the App was never installed on, which are precisely the ones registration refuses.
#
# ## What "an organization you can register from" means here
#
# It means: an organization with at least one repository that is in this viewer's installation AND
# that GitHub names this viewer an administrator of. Both halves, because either alone is a
# different and wrong page — installation alone offers an organization's read-only members fifty
# repositories the write will refuse, and administration alone would offer repositories nobody ever
# gave SpecGuard, which is the squatting gap this slice exists to close.
#
# That is deliberately NOT a claim about anybody's org role. An org owner still cannot register a
# repository nobody installed the App on, and somebody who administers exactly one repository can
# register exactly that one. The honest question is the one that decides the outcome, and it has
# already been decided upstream — by the installation for the repository, and by `permissions.admin`
# for the person.
#
# An organization with nothing registerable does not appear at all — the same choice the
# single-repository picker makes, and for the same reason: offering it is offering a click that can
# only end in an empty list. What was withheld from an organization that DOES appear is counted
# rather than hidden, so a short list is never a mysterious one.
#
# ## Personal repositories are out
#
# Only `owner.type == "Organization"` is grouped. A user's own namespace is not an organization, and
# SPGD-355 is scoped to "choose a GitHub org they administer" — a personal-namespace batch is the
# same machinery pointed at a different set and is left for whoever asks for it, rather than
# smuggled in under a page that says "organization".
class GithubOrganizations
  # One organization and every repository of its this viewer can see.
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

    # Repositories of this organization the viewer can see but cannot register. Stated as a count
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
