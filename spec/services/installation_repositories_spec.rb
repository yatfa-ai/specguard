# frozen_string_literal: true

require "rails_helper"

# "May this user register this repository?", answered by GitHub App installation membership.
#
# This is the file that pins the squatting gap closed. `GithubOwnership` used to answer the same
# question by reading `permissions.admin` off `GET /repos/:owner/:repo` over an OAuth `repo` grant —
# GitHub's "Full control of private repositories", read and write, across everything the user could
# reach — to get one boolean. The answer now comes from membership: only somebody who administers a
# repository can install a GitHub App on it, so a repository being IN the installation is GitHub's
# own statement that this user may register it.
#
# Every example here runs against `FakeGithubApi` through `GithubApi.factory`, so the listing a
# verdict is derived from is stated explicitly rather than mocked per call.
RSpec.describe InstallationRepositories do
  let(:user) { create_user }

  def verify(full_name, for_user: user)
    described_class.verify(user: for_user, full_name: full_name)
  end

  def statuses(*names, for_user: user)
    described_class.verify_batch(user: for_user, full_names: names).map(&:status)
  end

  describe ".sources" do
    it "reports what the installation covers" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      sources = described_class.sources(user)

      expect(sources).to be_installed
      expect(sources).to be_complete
      expect(sources.repos.map(&:full_name)).to eq(%w[acme/api acme/web])
    end

    # `installed?` is a fact about our own table, asked before any network call — so a page that
    # only needs to know whether there is anything to show does not pay a GitHub round trip to find
    # out there is not.
    it "reports a user who has not installed the App, without asking GitHub" do
      uninstall_github_app(user)
      fake = stub_github

      sources = described_class.sources(user)

      expect(sources).not_to be_installed
      expect(sources.repos).to be_empty
      expect(fake.calls).to be_empty
    end

    it "reports nobody at all as not installed" do
      expect(described_class.sources(nil)).not_to be_installed
    end

    # Two admins of the same organization legitimately reach the same repositories through
    # different installations, and an organization installation and a personal one can both reach a
    # fork. The picker must offer it once.
    it "merges several installations and de-duplicates across them" do
      add_github_installation(user, installation_id: 6002)
      allow(GithubApi).to receive(:for_installation) do |installation|
        id = installation.respond_to?(:installation_id) ? installation.installation_id : installation
        if id == 6002
          FakeGithubApi.new(repos: [github_repo("acme/web"), github_repo("beta/thing")])
        else
          FakeGithubApi.new(repos: [github_repo("acme/api"), github_repo("acme/web")])
        end
      end

      sources = described_class.sources(user)

      expect(sources.repos.map(&:full_name)).to eq(%w[acme/api acme/web beta/thing])
    end

    # Ordering is established HERE and inherited by everything downstream — the picker, the
    # organization grouping — so a list merged from two installations reads alphabetically rather
    # than installation by installation. GitHub's ASCII order would put every capital first.
    it "sorts the merged listing case-insensitively by name" do
      stub_github(repos: [github_repo("acme/zebra"), github_repo("acme/Apple")])

      expect(described_class.sources(user).repos.map(&:full_name)).to eq(%w[acme/Apple acme/zebra])
    end

    # An uninstalled installation contains no repositories, which is a COMPLETE answer rather than a
    # gap in what we know. Reporting it as an error would send every name in a batch on a per-name
    # round trip to the same 404.
    it "treats an uninstalled installation as empty rather than as a failure" do
      stub_github(not_found: true)

      sources = described_class.sources(user)

      expect(sources.repos).to be_empty
      expect(sources.error).to be_nil
      expect(sources).to be_complete
    end

    it "records a failure without raising" do
      stub_github(unavailable: true)

      sources = described_class.sources(user)

      expect(sources.error).to eq(:unavailable)
      expect(sources).not_to be_complete
      expect(sources).to be_installed
    end

    # One failing installation must not sink the others. What was read is still GitHub's own answer
    # and is not made less true by a different installation being unreachable — so those
    # repositories stay registerable, and the failure changes only what an ABSENT name means.
    it "keeps the repositories it could read when another installation fails" do
      add_github_installation(user, installation_id: 6002)
      allow(GithubApi).to receive(:for_installation) do |installation|
        id = installation.respond_to?(:installation_id) ? installation.installation_id : installation
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [github_repo("acme/api")] }))
      end

      sources = described_class.sources(user)

      expect(sources.repos.map(&:full_name)).to eq(%w[acme/api])
      expect(sources.error).to eq(:unavailable)
      expect(sources).not_to be_complete
    end
  end

  describe ".verify" do
    it "verifies a repository the installation covers" do
      stub_github(repos: [github_repo("acme/billing-service")])

      expect(verify("acme/billing-service")).to be_verified
    end

    # THE example, and the reason this class exists. A repository nobody installed the App on
    # cannot be registered however the name arrives — which is precisely the squatter's move.
    it "refuses a repository outside the installation" do
      stub_github(repos: [github_repo("acme/billing-service")])

      verdict = verify("someone-else/private-repo")

      expect(verdict).not_to be_verified
      expect(verdict.status).to eq(:not_in_installation)
      expect(verdict.message).to include("SpecGuard GitHub App is installed on")
    end

    # GitHub logins and repository names are case-insensitive, and a name may arrive here having
    # been round-tripped through a form.
    it "matches a name whatever its case" do
      stub_github(repos: [github_repo("acme/Billing-Service")])

      expect(verify("ACME/billing-service")).to be_verified
    end

    # Asked of our own table before any network call: a user who has installed nothing has nothing
    # to ask GitHub WITH, and the answer is "install it", not "denied".
    it "reports a user who has installed nothing, and marks the fix as an installation" do
      uninstall_github_app(user)

      verdict = verify("acme/billing-service")

      expect(verdict.status).to eq(:not_installed)
      expect(verdict).to be_install
    end

    # `install?` is the predicate a form reads to decide between offering a button and offering a
    # field. Every other refusal is fixed on GitHub's configure page or not at all, so offering the
    # install button for one would be offering a click that changes nothing.
    it "marks nothing but a missing installation as fixable by installing" do
      stub_github(repos: [])
      expect(verify("acme/billing-service")).not_to be_install

      stub_github(unavailable: true)
      expect(verify("acme/billing-service")).not_to be_install
    end

    # FAILS CLOSED. If an outage were a pass, the gap would reopen on every GitHub 500 — which is a
    # worse property than the one being fixed, because it is intermittent and nobody would notice.
    it "refuses while GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect(verify("acme/billing-service").status).to eq(:unavailable)
    end

    # An operator-side failure — a wrong App id, a private key that is not this App's — is nothing
    # a user can act on, so they get the same sentence an outage gets and the reason goes to the log.
    it "refuses, as an outage, when GitHub rejects the App's own credentials" do
      stub_github(unauthorized: true)

      expect(verify("acme/billing-service").status).to eq(:unavailable)
    end

    # A rate limit is the one refusal that genuinely clears by waiting, so it says so rather than
    # being folded into the outage that also says "try again" but never resolves.
    it "names a rate limit rather than reporting it as an outage" do
      stub_github(forbidden: :rate_limited)

      verdict = verify("acme/billing-service")

      expect(verdict.status).to eq(:rate_limited)
      expect(verdict.message).to include("rate limit")
    end

    it "reports a refusal that is not a rate limit as an outage the user cannot act on" do
      stub_github(forbidden: :refused)

      expect(verify("acme/billing-service").status).to eq(:unavailable)
    end
  end

  describe ".verify_batch" do
    it "answers one verdict per name, in the order given" do
      stub_github(repos: [github_repo("acme/api")])

      expect(statuses("acme/api", "ghost/repo", "acme/api"))
        .to eq(%i[verified not_in_installation verified])
    end

    # Membership is a set test over a listing SpecGuard has to fetch either way, so twenty names
    # cost what one name costs. A per-name round trip would be twenty sequential calls before the
    # first row is saved.
    it "asks GitHub once however many names were submitted" do
      fake = stub_github(repos: [github_repo("acme/api")])

      described_class.verify_batch(user: user, full_names: %w[acme/api acme/web beta/x ghost/y])

      expect(fake.calls_to(:repositories)).to eq(1)
    end

    it "ignores blank entries and answers nothing for an empty submission" do
      stub_github(repos: [github_repo("acme/api")])

      expect(described_class.verify_batch(user: user, full_names: [" ", nil])).to eq([])
      expect(statuses("acme/api", "")).to eq(%i[verified])
    end

    it "gives every name the same answer when the App is not installed" do
      uninstall_github_app(user)

      expect(statuses("acme/api", "acme/web")).to eq(%i[not_installed not_installed])
    end

    # Nothing is registered on a GitHub outage, for the reason the single path states: verifying by
    # default during an outage reopens the gap intermittently, which is worse than the gap itself.
    it "gives every name the failure when the listing could not be read" do
      stub_github(unavailable: true)

      expect(statuses("acme/api", "acme/web")).to eq(%i[unavailable unavailable])
    end
  end

  # `MAX_PAGES` bounds each installation's page walk, and an installation can fail while others
  # succeed. Either way a name can be absent from the merged set for a reason that is OURS rather
  # than GitHub's — so absence is reported as a refusal only when the reading was complete.
  describe "when the reading was incomplete" do
    it "asks GitHub about an absent name individually rather than refusing it" do
      fake = stub_github(repos: [github_repo("acme/api")], truncated: true)

      # Absent from the truncated listing, but GitHub knows it: the fake answers `repository` for
      # anything it holds, and here it holds only `acme/api` — so this one is still refused, and the
      # point is that it was ASKED rather than refused off our own page walk.
      expect(verify("ghost/repo").status).to eq(:not_in_installation)
      expect(fake.calls_to(:repository)).to eq(1)
    end

    it "verifies a name the individual ask finds" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/late")], truncated: true)

      # `acme/late` is in the fake's set, so the per-name ask finds it even though this pins the
      # truncated path — the set test would have found it too, which is why the call count above is
      # the assertion that the fallback ran at all.
      expect(verify("acme/late")).to be_verified
    end

    # The fallback must not invent a refusal. An installation that would not list its repositories
    # will not answer about one of them either, and reporting that as "GitHub says this is not
    # yours" would turn our ignorance into GitHub's verdict.
    it "reports the failure rather than a refusal when nothing can answer" do
      stub_github(unavailable: true)

      expect(verify("acme/api").status).to eq(:unavailable)
    end

    # A truncated listing whose per-name ask ALSO fails is the same situation one step further in.
    it "reports the failure when the individual ask fails too" do
      add_github_installation(user, installation_id: 6002)
      allow(GithubApi).to receive(:for_installation) do |installation|
        id = installation.respond_to?(:installation_id) ? installation.installation_id : installation
        if id == 6002
          FakeGithubApi.new(unavailable: true)
        else
          FakeGithubApi.new(repos: [github_repo("acme/api")], truncated: true)
        end
      end

      expect(verify("ghost/repo").status).to eq(:unavailable)
    end

    # The per-name fallback is unbounded in principle, which is why `BulkRegistration::MAX_BATCH`
    # bounds the input: the cap on the batch is what keeps the cap on the listing from turning into
    # an unbounded fan-out.
    it "asks once per absent name, not once per name" do
      fake = stub_github(repos: [github_repo("acme/api")], truncated: true)

      described_class.verify_batch(user: user, full_names: %w[acme/api ghost/one ghost/two])

      expect(fake.calls_to(:repository)).to eq(2)
    end
  end
end
