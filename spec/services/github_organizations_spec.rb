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

    # `owner.type` is the only field that answers this. The owner SEGMENT of `full_name` cannot:
    # `octocat/dotfiles` and `acme/api` are the same shape, and a person may well be called `acme`.
    it "leaves personal repositories out — a user's own namespace is not an organization" do
      orgs = described_class.from(listing([github_repo("acme/api"),
                                           github_repo("octocat/dotfiles", owner_type: "User")]))

      expect(orgs.map(&:login)).to eq(%w[acme])
    end

    # A repository GitHub reported without an owner type is not evidence of an organization. It
    # withholds rather than inventing — the same fail-closed reflex the whole slice rests on.
    it "leaves a repository whose owner type GitHub did not report out" do
      unknown = GithubApi::Repo.new(full_name: "mystery/repo", private: false, archived: false)

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
  end
end
