# frozen_string_literal: true

require "rails_helper"

# The organizations a user can bulk-register from, derived from the installation listing they
# already have rather than from GitHub's org endpoints. Every example here is about the DERIVATION
# — what gets grouped and what gets offered.
#
# There is no "withheld" half any more, and its absence is the substance of SPGD-424: the OAuth
# listing returned every repository the user could reach and this class had to filter it down to the
# ones they administered. An installation contains only what somebody who administers those
# repositories deliberately selected, so everything in it is registerable.
RSpec.describe GithubOrganizations do
  def listing(repos, truncated: false)
    GithubApi::Listing.new(repos: repos, truncated: truncated)
  end

  describe ".from" do
    it "groups an organization's repositories under its login" do
      orgs = described_class.from(listing([github_repo("acme/api"), github_repo("acme/web")]))

      expect(orgs.map(&:login)).to eq(%w[acme])
      expect(orgs.first.repos.map(&:full_name)).to eq(%w[acme/api acme/web])
    end

    # SPGD-818 reversed this. It used to read "leaves personal repositories out — a user's own
    # namespace is not an organization", and that filter was the whole of the bug: a solo developer
    # with twenty repositories in their own namespace was told the batch page was not for them,
    # while every step downstream of the chooser gated on `admin?` and would have taken all twenty.
    #
    # `admin?` is the sole gate and always was. Owner type now decides only what a card is
    # LABELLED, which is what `#organization?` and `#personal?` below are for.
    it "groups a personal namespace exactly as it groups an organization" do
      orgs = described_class.from(listing([github_repo("acme/api"),
                                           github_repo("octocat/dotfiles", owner_type: "User")]))

      expect(orgs.map(&:login)).to eq(%w[acme octocat])
      expect(orgs.map(&:administered_count)).to eq([1, 1])
    end

    # Criterion 1: the case the ticket opens with. A listing that is ENTIRELY personal used to
    # produce an empty chooser and the "not for you" empty state; it now produces a real one.
    it "offers a listing that is entirely personal" do
      orgs = described_class.from(listing([github_repo("octocat/dotfiles", owner_type: "User"),
                                           github_repo("octocat/blog", owner_type: "User")]))

      expect(orgs.map(&:login)).to eq(%w[octocat])
      expect(orgs.first.administered.map(&:full_name)).to eq(%w[octocat/blog octocat/dotfiles])
    end

    # Criterion 3: one order over both kinds, by downcased login — a personal namespace does not
    # sort into a section of its own, because it is not a different kind of choice.
    it "orders personal namespaces and organizations together, alphabetically" do
      orgs = described_class.from(listing([github_repo("Zebra/x"),
                                           github_repo("octocat/dotfiles", owner_type: "User"),
                                           github_repo("acme/y")]))

      expect(orgs.map(&:login)).to eq(%w[acme octocat Zebra])
      expect(orgs.map(&:organization?)).to eq([true, false, true])
      expect(orgs.map(&:personal?)).to eq([false, true, false])
    end

    # Criterion 4: the two counts are per NAMESPACE and computed identically for both kinds —
    # `withheld_count` reads `admin?`, which never asked what sort of owner it was looking at.
    it "counts what may be registered and what is withheld in a personal namespace too" do
      orgs = described_class.from(listing([
                                            github_repo("octocat/dotfiles", owner_type: "User"),
                                            github_repo("octocat/theirs", owner_type: "User", admin: false)
                                          ]))

      expect(orgs.map(&:login)).to eq(%w[octocat])
      expect(orgs.first.administered_count).to eq(1)
      expect(orgs.first.withheld_count).to eq(1)
    end

    # Criterion 6: the negative control. Widening the chooser widened what is DISPLAYED and nothing
    # about what is permitted — a personal repository the viewer does not administer is still not
    # offered, exactly as an organization's is not.
    it "still leaves out a personal namespace the viewer administers nothing in" do
      orgs = described_class.from(listing([github_repo("acme/api"),
                                           github_repo("octocat/theirs", owner_type: "User",
                                                                         admin: false)]))

      expect(orgs.map(&:login)).to eq(%w[acme])
    end

    # Criterion 5, and the one deliberate behaviour change SPGD-818 records under its own heading.
    # This example used to read "leaves a repository whose owner type GitHub did not report out":
    # a nil owner type read as "not an organization" and the repository was dropped entirely.
    #
    # Now nil decides nothing about whether a repository is OFFERED — `admin?` does — and it still
    # decides nothing about the label either. The card carries NO marker rather than a "Personal"
    # one, because `personal?` is a positive claim about what GitHub said and not the negation of
    # `organization?`. Withholding rather than inventing, the doctrine `github_api.rb:145-149`
    # states for that default, and the reason `Org` has two predicates instead of one.
    it "offers a repository whose owner type GitHub did not report, and marks it as neither" do
      unknown = GithubApi::Repo.new(full_name: "mystery/repo", private: false, archived: false,
                                    admin: true)

      org = described_class.from(listing([unknown])).first

      expect(org.login).to eq("mystery")
      expect(org.administered.map(&:full_name)).to eq(%w[mystery/repo])
      expect(org).not_to be_organization
      expect(org).not_to be_personal
    end

    # And the gate still applies to it: an unreported owner type is not a way around `admin?`.
    it "leaves out an unreported namespace the viewer administers nothing in" do
      unknown = GithubApi::Repo.new(full_name: "mystery/repo", private: false, archived: false,
                                    admin: false)

      expect(described_class.from(listing([unknown]))).to be_empty
    end

    # The two counts a card is built from, and the reason `Org` holds the unfiltered set: the badge
    # is what may be selected, and the sentence under it is why the organization is bigger than that.
    it "counts what may be registered and what is being withheld, per organization" do
      orgs = described_class.from(listing([github_repo("acme/api"), github_repo("acme/legacy", admin: false),
                                           github_repo("beta/thing")]))

      expect(orgs.map(&:login)).to eq(%w[acme beta])
      expect(orgs.map(&:administered_count)).to eq([1, 1])
      expect(orgs.map(&:withheld_count)).to eq([1, 0])
      expect(orgs.map(&:any_administered?)).to all(be(true))
    end

    # An organization the viewer administers nothing in is not offered at all — a card leading to an
    # empty picker is a click that can only disappoint. It is the ONE case where something is hidden
    # rather than counted, because there is no card left to hang the count on.
    it "leaves out an organization the viewer administers nothing in" do
      orgs = described_class.from(listing([github_repo("acme/api"),
                                           github_repo("beta/thing", admin: false)]))

      expect(orgs.map(&:login)).to eq(%w[acme])
    end

    # `administered` re-sorts case-insensitively where `repos` does not, because it is the picker's
    # own order rather than the listing's.
    it "offers an organization's administered repositories alphabetically, case-insensitively" do
      org = described_class.from(listing([github_repo("acme/zebra"), github_repo("acme/Apple"),
                                          github_repo("acme/hidden", admin: false)])).first

      expect(org.administered.map(&:full_name)).to eq(%w[acme/Apple acme/zebra])
      expect(org.withheld_count).to eq(1)
    end

    it "orders organizations alphabetically, case-insensitively" do
      orgs = described_class.from(listing([github_repo("Zebra/x"), github_repo("acme/y"),
                                           github_repo("Beta/z")]))

      expect(orgs.map(&:login)).to eq(%w[acme Beta Zebra])
    end

    # Ordering WITHIN an organization is inherited rather than re-applied. Both producers of a
    # listing sort it case-insensitively by name — `GithubApi#repositories` and
    # `InstallationRepositories.sources` — so sorting again here would be a second place for the
    # rule to live and a second place for it to drift. Grouping preserves the order it was given.
    it "keeps an organization's repositories in the order the listing supplied" do
      org = described_class.from(listing([github_repo("acme/Apple"), github_repo("acme/zebra")])).first

      expect(org.repos.map(&:full_name)).to eq(%w[acme/Apple acme/zebra])
    end

    it "answers with nothing at all when there is no listing to derive from" do
      expect(described_class.from(nil)).to eq([])
    end
  end

  describe ".find" do
    let(:repos) { [github_repo("acme/api"), github_repo("beta/x")] }

    it "finds an organization by login" do
      expect(described_class.find(listing(repos), "acme").login).to eq("acme")
    end

    # GitHub logins are case-insensitive, and this value arrives from a query string that a person
    # can type and a bookmark can carry a differently-cased copy of.
    it "finds an organization whatever the case of the login asked for" do
      expect(described_class.find(listing(repos), "ACME").login).to eq("acme")
    end

    # A stale bookmark and a renamed organization are ordinary ways to arrive here. The caller
    # renders the chooser again; nothing raises.
    it "answers nil for an organization this listing cannot register from" do
      expect(described_class.find(listing(repos), "strangers")).to be_nil
      expect(described_class.find(listing(repos), "")).to be_nil
      expect(described_class.find(listing(repos), nil)).to be_nil
    end

    # Criterion 7. `.find` reads whatever `.from` offers, so widening the chooser widened this too
    # — the second step of the flow resolves a personal login on the same terms, and with the same
    # case-insensitivity, or step one would offer a card that step two could not open.
    it "finds a personal namespace by login, whatever its case" do
      personal = listing([github_repo("octocat/dotfiles", owner_type: "User")])

      expect(described_class.find(personal, "octocat").login).to eq("octocat")
      expect(described_class.find(personal, "OCTOCAT").login).to eq("octocat")
    end

    # And the gate holds on this path too: a namespace whose repositories the viewer does not
    # administer is not resolvable by typing its login into the query string.
    it "answers nil for a personal namespace the viewer administers nothing in" do
      personal = listing([github_repo("octocat/theirs", owner_type: "User", admin: false)])

      expect(described_class.find(personal, "octocat")).to be_nil
    end
  end
end
