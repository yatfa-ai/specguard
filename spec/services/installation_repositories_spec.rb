# frozen_string_literal: true

require "rails_helper"

# "May this user register this repository?" — the file that pins the squatting gap closed.
#
# The answer takes TWO conditions and this file exists to hold both of them down:
#
#   1. the repository is in one of this user's GitHub App installations, and
#   2. GitHub reports THIS user as an administrator of it.
#
# An earlier version enforced only the first, on the argument that only an administrator can install
# an App — which is true of whoever installed it and says nothing about whoever is reading it. GitHub
# shows an organization's installation to every member of that organization, so the missing second
# condition let a read-only member register every repository in their employer's installation. The
# examples about `admin: false` and about one user reading another's installation are that hole, and
# they are the reason the credential every read is made with is the USER's own.
#
# Every example runs against `FakeGithubApi` through `GithubApi.factory`, so the listing a verdict is
# derived from is stated explicitly rather than mocked per call.
RSpec.describe InstallationRepositories do
  let(:user) { create_user }
  let(:token) { "ghu_octocat" }

  def sources(for_user: user, user_token: token)
    described_class.sources(for_user, user_token: user_token)
  end

  def verify(full_name, for_user: user, user_token: token)
    described_class.verify(user: for_user, full_name: full_name, user_token: user_token)
  end

  def statuses(*names, for_user: user, user_token: token)
    described_class.verify_batch(user: for_user, full_names: names, user_token: user_token).map(&:status)
  end

  describe ".sources" do
    it "reports what the user can reach in the installation" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      result = sources

      expect(result).to be_installed
      expect(result).to be_complete
      expect(result.repos.map(&:full_name)).to eq(%w[acme/api acme/web])
    end

    # THE credential assertion. Everything else in this file rests on the read being made as the
    # user rather than as the App: an App credential answers the same for every member of an
    # organization, and that is precisely the failure being fixed.
    it "reads as the user, with the user's own token and their own installation" do
      fake = stub_github

      sources

      expect(fake.token).to eq(token)
      expect(fake.installation_id).to eq(user.github_installations.first.installation_id)
    end

    # `installed?` is a fact about our own table, asked before any network call — so a page that
    # only needs to know whether there is anything to show does not pay a GitHub round trip to find
    # out there is not.
    it "reports a user who has not installed the App, without asking GitHub" do
      uninstall_github_app(user)
      fake = stub_github

      result = sources

      expect(result).not_to be_installed
      expect(result.repos).to be_empty
      expect(fake.calls).to be_empty
    end

    it "reports nobody at all as not installed" do
      expect(sources(for_user: nil)).not_to be_installed
    end

    # A session with no credential is not the same as an outage and not the same as an empty
    # installation: it is the ordinary state of a returning user's first page load, and it has a
    # one-click fix. GitHub is not called, because there is nothing to call it with.
    it "reports a session with no credential without asking GitHub" do
      fake = stub_github

      result = sources(user_token: nil)

      expect(result).to be_installed
      expect(result.error).to eq(:not_authorized)
      expect(result.repos).to be_empty
      expect(fake.calls).to be_empty
    end

    # `repos` carries everything the user can SEE so the two refusals can be told apart;
    # `registrable` — which is what the picker is built from — carries only what they administer.
    it "offers only the repositories the user administers" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/readonly", admin: false)])

      result = sources

      expect(result.repos.map(&:full_name)).to eq(%w[acme/api acme/readonly])
      expect(result.registrable.map(&:full_name)).to eq(%w[acme/api])
      expect(result.listing.repos.map(&:full_name)).to eq(%w[acme/api])
    end

    # The other half of the same fact, and the one a picker needs in order to account for its own
    # length: what was withheld is counted and still reachable, rather than dropped. A page that
    # shows one of three connected repositories and says nothing reads as broken.
    it "keeps what it withheld, so a picker can say how much it is not showing" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/readonly", admin: false),
                          github_repo("acme/vault", admin: false)])

      result = sources

      expect(result.withheld_count).to eq(2)
      expect(result.visible_listing.repos.map(&:full_name))
        .to eq(%w[acme/api acme/readonly acme/vault])
    end

    it "counts nothing as withheld when the user administers everything they can reach" do
      stub_github(repos: [github_repo("acme/api")])

      expect(sources.withheld_count).to eq(0)
    end

    # Two admins of the same organization legitimately reach the same repositories through
    # different installations, and an organization installation and a personal one can both reach a
    # fork. The picker must offer it once.
    it "merges several installations and de-duplicates across them" do
      add_github_installation(user, installation_id: 6002)
      stub_github_per_installation do |id|
        if id == 6002
          FakeGithubApi.new(repos: [github_repo("acme/web"), github_repo("beta/thing")])
        else
          FakeGithubApi.new(repos: [github_repo("acme/api"), github_repo("acme/web")])
        end
      end

      expect(sources.repos.map(&:full_name)).to eq(%w[acme/api acme/web beta/thing])
    end

    # Where two installations disagree about the same repository, the permissive reading wins: both
    # are GitHub's answer about the SAME user, and being an administrator through one route is being
    # an administrator.
    it "keeps the administered reading when two installations disagree" do
      add_github_installation(user, installation_id: 6002)
      stub_github_per_installation do |id|
        FakeGithubApi.new(repos: [github_repo("acme/web", admin: id == 6002)])
      end

      expect(sources.registrable.map(&:full_name)).to eq(%w[acme/web])
    end

    # Ordering is established HERE and inherited by everything downstream — the picker, the
    # organization grouping — so a list merged from two installations reads alphabetically rather
    # than installation by installation. GitHub's ASCII order would put every capital first.
    it "sorts the merged listing case-insensitively by name" do
      stub_github(repos: [github_repo("acme/zebra"), github_repo("acme/Apple")])

      expect(sources.repos.map(&:full_name)).to eq(%w[acme/Apple acme/zebra])
    end

    # An installation this user can no longer reach contains nothing they may register, which is a
    # COMPLETE answer rather than a gap in what we know.
    it "treats an unreachable installation as empty rather than as a failure" do
      stub_github(not_found: true)

      result = sources

      expect(result.repos).to be_empty
      expect(result.error).to be_nil
      expect(result).to be_complete
    end

    it "records a failure without raising" do
      stub_github(unavailable: true)

      result = sources

      expect(result.error).to eq(:unavailable)
      expect(result).not_to be_complete
      expect(result).to be_installed
    end

    # A token GitHub rejects is a different thing from an outage, and the difference is that the
    # user can fix it. Reporting it as an outage would offer them "try again shortly" forever.
    it "reports a rejected token as an authorization to repeat, not as an outage" do
      stub_github(unauthorized: true)

      expect(sources.error).to eq(:not_authorized)
    end

    # One failing installation must not sink the others. What was read is still GitHub's own answer
    # and is not made less true by a different installation being unreachable — so those
    # repositories stay registerable, and the failure changes only what an ABSENT name means.
    it "keeps the repositories it could read when another installation fails" do
      add_github_installation(user, installation_id: 6002)
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [github_repo("acme/api")] }))
      end

      result = sources

      expect(result.repos.map(&:full_name)).to eq(%w[acme/api])
      expect(result.error).to eq(:unavailable)
      expect(result).not_to be_complete
    end
  end

  describe ".verify" do
    it "verifies a repository the user administers in the installation" do
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

    # THE OTHER example, and the one a green suite missed. The repository IS in the installation and
    # this user is not an administrator of it: the position of every read-only member of every
    # organization that installs the App.
    it "refuses a repository in the installation that the user does not administer" do
      stub_github(repos: [github_repo("acme/billing", admin: false)])

      verdict = verify("acme/billing")

      expect(verdict).not_to be_verified
      expect(verdict.status).to eq(:not_administered)
      expect(verdict.message).to include("administrator")
    end

    # The reviewer's scenario, end to end and at the level it actually bites: user A records an
    # installation, user B holds a row for the SAME installation — which GitHub hands to any member
    # of the organization — and B's read is made with B's credential, so B sees what B administers
    # and nothing else. Under an App-credential read both users saw the identical fifty rows.
    #
    # ONE fake, keyed on the token, deliberately. Re-stubbing between the two calls would produce
    # the same two verdicts against a `sources` that hard-coded a constant credential — which is
    # precisely the regression this example exists to catch, so it has to be the reader that decides
    # the answer and not the setup.
    it "answers per user when two users hold the same installation" do
      owner = create_user(github_uid: "1001", github_handle: "owner", installation_id: 9001)
      member = create_user(github_uid: "2002", github_handle: "member", installation_id: 9001)

      stub_github_per_credential do |token, installation_id|
        raise "expected the shared installation, got #{installation_id}" unless installation_id == 9001

        FakeGithubApi.new(repos: [github_repo("acme/billing", admin: token == "ghu_owner"),
                                  github_repo("acme/docs", admin: token == "ghu_owner")])
      end

      expect(described_class.verify(user: owner, full_name: "acme/billing",
                                    user_token: "ghu_owner")).to be_verified

      # Same installation, same repositories, different reader — GitHub answers the member with
      # their own permissions, and `acme/billing` is not one they administer.
      verdict = described_class.verify(user: member, full_name: "acme/billing", user_token: "ghu_member")

      expect(verdict).not_to be_verified
      expect(verdict.status).to eq(:not_administered)
    end

    # GitHub logins and repository names are case-insensitive, and a name may arrive here having
    # been round-tripped through a form.
    it "matches a name whatever its case" do
      stub_github(repos: [github_repo("acme/Billing-Service")])

      expect(verify("ACME/billing-service")).to be_verified
    end

    # Asked of our own table before any network call: a user who has installed nothing has nothing
    # to ask GitHub about, and the answer is "install it", not "denied".
    it "reports a user who has installed nothing, and marks the fix as an installation" do
      uninstall_github_app(user)

      verdict = verify("acme/billing-service")

      expect(verdict.status).to eq(:not_installed)
      expect(verdict).to be_install
      expect(verdict).not_to be_authorize
    end

    # The other button. Nothing is wrong with the installation and nothing is wrong with the
    # repository — the session simply has no credential, which is what a returning user's first
    # page load looks like.
    it "reports a session with no credential, and marks the fix as an authorization" do
      verdict = verify("acme/billing-service", user_token: nil)

      expect(verdict.status).to eq(:not_authorized)
      expect(verdict).to be_authorize
      expect(verdict).not_to be_install
    end

    # `install?` and `authorize?` are the predicates a form reads to decide between offering a
    # button and offering a field. Every other refusal is fixed on GitHub's configure page or not at
    # all, so offering either button for one would be offering a click that changes nothing.
    it "marks no other refusal as fixable by a button" do
      stub_github(repos: [])
      expect(verify("acme/billing-service")).not_to be_install

      stub_github(repos: [github_repo("acme/billing-service", admin: false)])
      expect(verify("acme/billing-service")).not_to be_install
      expect(verify("acme/billing-service")).not_to be_authorize

      stub_github(unavailable: true)
      expect(verify("acme/billing-service")).not_to be_install
      expect(verify("acme/billing-service")).not_to be_authorize
    end

    # FAILS CLOSED. If an outage were a pass, the gap would reopen on every GitHub 500 — which is a
    # worse property than the one being fixed, because it is intermittent and nobody would notice.
    it "refuses while GitHub cannot be reached" do
      stub_github(unavailable: true)

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
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/readonly", admin: false)])

      expect(statuses("acme/api", "ghost/repo", "acme/readonly", "acme/api"))
        .to eq(%i[verified not_in_installation not_administered verified])
    end

    # The answer is a set test over a listing SpecGuard has to fetch either way, so twenty names
    # cost what one name costs. A per-name round trip would be twenty sequential calls before the
    # first row is saved.
    it "asks GitHub once however many names were submitted" do
      fake = stub_github(repos: [github_repo("acme/api")])

      described_class.verify_batch(user: user, user_token: token,
                                   full_names: %w[acme/api acme/web beta/x ghost/y])

      expect(fake.calls_to(:repositories)).to eq(1)
    end

    it "ignores blank entries and answers nothing for an empty submission" do
      stub_github(repos: [github_repo("acme/api")])

      expect(described_class.verify_batch(user: user, user_token: token, full_names: [" ", nil])).to eq([])
      expect(statuses("acme/api", "")).to eq(%i[verified])
    end

    it "gives every name the same answer when the App is not installed" do
      uninstall_github_app(user)

      expect(statuses("acme/api", "acme/web")).to eq(%i[not_installed not_installed])
    end

    it "gives every name the same answer when the session holds no credential" do
      expect(statuses("acme/api", "acme/web", user_token: nil)).to eq(%i[not_authorized not_authorized])
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
    # There is deliberately no per-name fallback. It could only be asked of `GET /repos/:owner/:repo`,
    # which is NOT installation-scoped: a user token answers it for any repository that user can see,
    # including ones nobody ever gave SpecGuard. A fallback would have admitted exactly what this
    # class exists to refuse, so an incomplete reading fails closed instead — and GitHub is not asked
    # a second time, which is also what stops a large batch fanning out into hundreds of round trips.
    it "refuses an absent name rather than asking about it individually" do
      fake = stub_github(repos: [github_repo("acme/api")], truncated: true)

      expect(verify("ghost/repo").status).to eq(:unavailable)
      expect(fake.calls_to(:repositories)).to eq(1)
    end

    # A name that IS in the part that was read is still answered from it — truncation makes absence
    # meaningless, not presence.
    it "still verifies a name the incomplete reading did contain" do
      stub_github(repos: [github_repo("acme/api")], truncated: true)

      expect(verify("acme/api")).to be_verified
    end

    it "reports the recorded failure rather than inventing a refusal" do
      stub_github(forbidden: :rate_limited)

      expect(verify("acme/api").status).to eq(:rate_limited)
    end

    it "asks GitHub once for a whole batch it cannot fully answer" do
      fake = stub_github(repos: [github_repo("acme/api")], truncated: true)

      statuses = described_class.verify_batch(user: user, user_token: token,
                                              full_names: %w[acme/api ghost/one ghost/two]).map(&:status)

      expect(statuses).to eq(%i[verified unavailable unavailable])
      expect(fake.calls_to(:repositories)).to eq(1)
    end
  end
end
