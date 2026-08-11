# frozen_string_literal: true

require "rails_helper"

# The organizations a user can bulk-register from, derived from the repository listing they already
# have rather than from GitHub's org endpoints. Every example here is about the DERIVATION — what
# gets grouped, what gets offered, and what is deliberately withheld.
RSpec.describe GithubOrganizations do
  def listing(repos, truncated: false)
    GithubApi::Listing.new(repos: repos, truncated: truncated)
  end

  describe ".from" do
    it "groups an organization's repositories under its login" do
      orgs = described_class.from(listing([github_repo("acme/api"), github_repo("acme/web")]))

      expect(orgs.map(&:login)).to eq(%w[acme])
      expect(orgs.first.administered.map(&:full_name)).to eq(%w[acme/api acme/web])
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
      unknown = GithubApi::Repo.new(full_name: "mystery/repo", private: false, admin: true,
                                    archived: false)

      expect(described_class.from(listing([unknown]))).to be_empty
    end

    # The operative predicate: registration is per repository and gated per repository, so an
    # organization you can see but administer nothing in is a click that can only end in an empty
    # list.
    it "does not offer an organization the user administers nothing in" do
      orgs = described_class.from(listing([github_repo("acme/api", admin: true),
                                           github_repo("readonly/thing", admin: false)]))

      expect(orgs.map(&:login)).to eq(%w[acme])
    end

    # Withheld, not hidden. The count is what keeps a short list from being a mysterious one.
    it "counts the repositories it withheld from an organization it does offer" do
      org = described_class.from(listing([github_repo("acme/api", admin: true),
                                          github_repo("acme/legacy", admin: false),
                                          github_repo("acme/old", admin: false)])).first

      expect(org.administered_count).to eq(1)
      expect(org.withheld_count).to eq(2)
    end

    it "orders organizations alphabetically, case-insensitively" do
      orgs = described_class.from(listing([github_repo("Zebra/x"), github_repo("acme/y"),
                                           github_repo("Beta/z")]))

      expect(orgs.map(&:login)).to eq(%w[acme Beta Zebra])
    end

    # GitHub's ASCII order puts every capital ahead of every lowercase, which reads as a broken
    # list rather than as an ordering.
    it "orders an organization's repositories case-insensitively by name" do
      org = described_class.from(listing([github_repo("acme/zebra"), github_repo("acme/Apple")])).first

      expect(org.administered.map(&:full_name)).to eq(%w[acme/Apple acme/zebra])
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
