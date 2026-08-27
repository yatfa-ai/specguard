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
# ## What "a namespace you can register from" means here
#
# It means: an owner with at least one repository that is in this viewer's installation AND that
# GitHub names this viewer an administrator of. Both halves, because either alone is a different and
# wrong page — installation alone offers an organization's read-only members fifty repositories the
# write will refuse, and administration alone would offer repositories nobody ever gave SpecGuard,
# which is the squatting gap this slice exists to close.
#
# That is deliberately NOT a claim about anybody's org role. An org owner still cannot register a
# repository nobody installed the App on, and somebody who administers exactly one repository can
# register exactly that one. The honest question is the one that decides the outcome, and it has
# already been decided upstream — by the installation for the repository, and by `permissions.admin`
# for the person.
#
# A namespace with nothing registerable does not appear at all — the same choice the
# single-repository picker makes, and for the same reason: offering it is offering a click that can
# only end in an empty list. What was withheld from a namespace that DOES appear is counted rather
# than hidden, so a short list is never a mysterious one.
#
# ## Personal namespaces are in — SPGD-818
#
# EVERY owner the viewer administers something in is grouped, their own namespace included.
# `admin?` is the sole gate and always was; owner type now decides only what a card is LABELLED,
# never whether it is offered.
#
# This reverses the deferral SPGD-355 wrote here, and it is worth saying why the reversal is not a
# silent widening of that scope. The objection recorded then was not that the machinery was wrong
# for a personal namespace — it is the same machinery pointed at a different set, and every step
# downstream (`Sources#registrable`, `#name_verdict`, all three of `BulkRegistration`'s passes)
# gates on `admin?` and reads no owner type at all. The objection was that offering one would be
# "smuggled in under a page that says organization". So the condition for lifting it was to stop the
# page saying that, and this change does both halves at once: the filter goes, and the views say
# which kind of namespace each card is. Landing either half alone is the failure this comment
# exists to prevent — the filter without the wording leaves the page lying, and the wording without
# the filter describes something the chooser cannot show.
#
# A solo developer with twenty repositories in their own namespace was told "Personal repositories
# are registered one at a time" and given a button to register them one at a time, while
# `BulkRegistration::MAX_BATCH` sat at 100 and would have taken all twenty.
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

    # Which KIND of namespace this is — read off the group's own repositories, since every
    # repository under one owner shares that owner's type. Asked only to LABEL a card; neither
    # predicate gates anything, and `admin?` above remains the sole bar on what is offered.
    #
    # They are two positive claims rather than one predicate and its negation, and that is the
    # whole point: GitHub may report no owner type at all, and `Repo#organization?` reads that nil
    # as "not an organization". Marking a card on `!organization?` would therefore print "Personal"
    # over a namespace GitHub never described — inventing the very fact `github_api.rb:145-149`
    # says to withhold. A third answer (neither, so no marker) is the honest one, and SPGD-818's
    # criterion 5 pins it.
    #
    # `any?` rather than reading `repos.first`: it survives an empty or mixed group without
    # depending on which entry happens to sort first, and cannot raise on a nil.
    def organization? = repos.any?(&:organization?)

    def personal? = !organization? && repos.any?(&:personal?)
  end

  class << self
    # Every namespace the viewer can register something from, alphabetically.
    #
    # Alphabetical rather than by size: a namespace is looked up by name (the reader knows which
    # one they came for), where a repository list is scanned, and "most repositories first" would
    # move the one they want as their access changes.
    #
    # There is no owner-type filter here — see the class comment. `any_administered?` is the only
    # thing that decides whether an owner appears, so a personal namespace is offered on exactly
    # the terms an organization is, and a repository whose owner type GitHub never reported is
    # grouped like any other rather than dropped for a fact nobody stated.
    def from(listing)
      return [] if listing.nil?

      listing.repos
             .group_by(&:owner)
             .map { |login, repos| Org.new(login: login, repos: repos) }
             .select(&:any_administered?)
             .sort_by { |org| org.login.downcase }
    end

    # One namespace by login, or `nil` when it is not one this viewer can register from.
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
