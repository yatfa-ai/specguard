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
    # @intent: { entity: "InstallationRepositories", action: "list reachable repositories", behavior: "the result reports installed and complete with exactly the repositories the fake installation holds", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "read with the user's own credential", behavior: "the listing is fetched with the user's token against their own installation id, never an App credential", layer: "unit" }
    it "reads as the user, with the user's own token and their own installation" do
      fake = stub_github

      sources

      expect(fake.token).to eq(token)
      expect(fake.installation_id).to eq(user.github_installations.first.installation_id)
    end

    # `installed?` is a fact about our own table, asked before any network call — so a page that
    # only needs to know whether there is anything to show does not pay a GitHub round trip to find
    # out there is not.
    # @intent: { entity: "InstallationRepositories", action: "short-circuit an uninstalled user", behavior: "a user with no installation row reports not installed and GitHub is not called at all", layer: "unit" }
    it "reports a user who has not installed the App, without asking GitHub" do
      uninstall_github_app(user)
      fake = stub_github

      result = sources

      expect(result).not_to be_installed
      expect(result.repos).to be_empty
      expect(fake.calls).to be_empty
    end

    # @intent: { entity: "InstallationRepositories", action: "report a nil user", behavior: "asking for a nil user reports not installed rather than raising", layer: "unit" }
    it "reports nobody at all as not installed" do
      expect(sources(for_user: nil)).not_to be_installed
    end

    # A session with no credential is not the same as an outage and not the same as an empty
    # installation: it is the ordinary state of a returning user's first page load, and it has a
    # one-click fix. GitHub is not called, because there is nothing to call it with.
    # @intent: { entity: "InstallationRepositories", action: "short-circuit a missing credential", behavior: "a nil user token yields installed with error :not_authorized and no GitHub call", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "filter registrable to administered", behavior: "repos keeps everything visible while registrable and the derived listing carry only administered repositories", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "keep the withheld visible", behavior: "non-administered repos are counted as withheld and remain present in visible_listing", layer: "unit" }
    it "keeps what it withheld, so a picker can say how much it is not showing" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/readonly", admin: false),
                          github_repo("acme/vault", admin: false)])

      result = sources

      expect(result.withheld_count).to eq(2)
      expect(result.visible_listing.repos.map(&:full_name))
        .to eq(%w[acme/api acme/readonly acme/vault])
    end

    # @intent: { entity: "InstallationRepositories", action: "count nothing withheld", behavior: "withheld_count is zero when every reachable repository is administered", layer: "unit" }
    it "counts nothing as withheld when the user administers everything they can reach" do
      stub_github(repos: [github_repo("acme/api")])

      expect(sources.withheld_count).to eq(0)
    end

    # Two admins of the same organization legitimately reach the same repositories through
    # different installations, and an organization installation and a personal one can both reach a
    # fork. The picker must offer it once.
    # @intent: { entity: "InstallationRepositories", action: "merge installations", behavior: "repositories across two installations are unioned, de-duplicated and sorted by name", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "resolve installation disagreement", behavior: "when two installations disagree on admin for one repo the administered reading wins and it stays registrable", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "sort the merged listing", behavior: "the union is ordered case-insensitively by full name rather than installation by installation", layer: "unit" }
    it "sorts the merged listing case-insensitively by name" do
      stub_github(repos: [github_repo("acme/zebra"), github_repo("acme/Apple")])

      expect(sources.repos.map(&:full_name)).to eq(%w[acme/Apple acme/zebra])
    end

    # An installation this user can no longer reach contains nothing they may register, which is a
    # COMPLETE answer rather than a gap in what we know.
    # @intent: { entity: "InstallationRepositories", action: "treat an unreachable installation as empty", behavior: "a 404 installation contributes no repos while leaving the result complete and error-free", layer: "unit" }
    it "treats an unreachable installation as empty rather than as a failure" do
      stub_github(not_found: true)

      result = sources

      expect(result.repos).to be_empty
      expect(result.error).to be_nil
      expect(result).to be_complete
    end

    # The attribution the pages are built from. It is recorded per INSTALLATION rather than merged,
    # because "which account is missing" is a different question from "what went wrong" and the
    # merged `error` cannot answer it: it keeps only the first failure and knows no names.
    # @intent: { entity: "InstallationRepositories", action: "report per-installation outcomes", behavior: "each installation's status and repo count are reported under the account name the user knows", layer: "unit" }
    it "reports what each installation answered, by the name the user knows it as" do
      add_github_installation(user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [github_repo("acme/api")] }))
      end

      outcomes = sources.outcomes.index_by(&:account)

      expect(outcomes.keys).to match_array(%w[acme globex])
      expect(outcomes["acme"]).to have_attributes(status: :read, count: 1)
      expect(outcomes["globex"]).to have_attributes(status: :unavailable, count: 0)
      expect(sources.unread_outcomes.map(&:account)).to eq(["globex"])
    end

    # The 404 is the case this attribution exists for. It is NOT an error — it stays out of `error`
    # and leaves `complete?` true, which is what keeps an absent name reported as GitHub's refusal
    # rather than as our ignorance — and it is nevertheless an account whose repositories are not on
    # the page. Both halves are asserted together because widening one into the other is the exact
    # mistake this shape prevents.
    # @intent: { entity: "InstallationRepositories", action: "report a 404 as unread", behavior: "a no-longer-listed installation surfaces as unreadable without setting error or breaking completeness", layer: "unit" }
    it "reports an installation GitHub no longer lists as unread without making it an error" do
      add_github_installation(user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { not_found: true } : { repos: [github_repo("acme/api")] }))
      end

      result = sources

      expect(result.unread_outcomes.map(&:account)).to eq(["globex"])
      expect(result.unread_outcomes.first).to be_unreadable
      expect(result.error).to be_nil
      expect(result).to be_complete
      expect(result.repos.map(&:full_name)).to eq(["acme/api"])
    end

    # An installation whose login was never recorded — a callback can arrive without one — is still
    # named, by the fallback `GithubInstallation#display_name` provides. A blank where the account
    # name goes would be worse than the anonymous sentence this replaced.
    # @intent: { entity: "InstallationRepositories", action: "name an unrecorded login", behavior: "an installation with no recorded login is named by its installation id fallback", layer: "unit" }
    it "names an installation with no recorded login by its fallback name" do
      add_github_installation(user, installation_id: 6002)
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [github_repo("acme/api")] }))
      end

      expect(sources.unread_outcomes.map(&:account)).to eq(["Installation 6002"])
    end

    # Nothing to explain when nothing is missing, and an empty list rather than a nil for the
    # callers that ask without checking.
    # @intent: { entity: "InstallationRepositories", action: "report nothing unread", behavior: "a fully successful read yields no unread outcomes", layer: "unit" }
    it "reports nothing unread when every installation answered" do
      stub_github(repos: [github_repo("acme/api")])

      expect(sources.unread_outcomes).to be_empty
      expect(sources.outcomes.map(&:status)).to eq([:read])
    end

    # @intent: { entity: "InstallationRepositories", action: "record an outage", behavior: "an unavailable installation sets the error and incompleteness without raising", layer: "unit" }
    it "records a failure without raising" do
      stub_github(unavailable: true)

      result = sources

      expect(result.error).to eq(:unavailable)
      expect(result).not_to be_complete
      expect(result).to be_installed
    end

    # A token GitHub rejects is a different thing from an outage, and the difference is that the
    # user can fix it. Reporting it as an outage would offer them "try again shortly" forever.
    # @intent: { entity: "InstallationRepositories", action: "distinguish a rejected token", behavior: "a 401 reads as :not_authorized rather than as an outage the user cannot fix", layer: "unit" }
    it "reports a rejected token as an authorization to repeat, not as an outage" do
      stub_github(unauthorized: true)

      expect(sources.error).to eq(:not_authorized)
    end

    # One failing installation must not sink the others. What was read is still GitHub's own answer
    # and is not made less true by a different installation being unreachable — so those
    # repositories stay registerable, and the failure changes only what an ABSENT name means.
    # @intent: { entity: "InstallationRepositories", action: "keep a partial read", behavior: "repositories from the healthy installation remain in the result while the failed one sets the error", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "verify an administered repo", behavior: "a repository the user administers inside the installation comes back verified", layer: "unit" }
    it "verifies a repository the user administers in the installation" do
      stub_github(repos: [github_repo("acme/billing-service")])

      expect(verify("acme/billing-service")).to be_verified
    end

    # THE example, and the reason this class exists. A repository nobody installed the App on
    # cannot be registered however the name arrives — which is precisely the squatter's move.
    # @intent: { entity: "InstallationRepositories", action: "refuse an outside repository", behavior: "a repository no installation contains is refused with :not_in_installation and a message naming the App", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "refuse a read-only member", behavior: "a reachable repository the user does not administer is refused with :not_administered", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "answer per user", behavior: "two users sharing one installation get verdicts driven by their own credentials so only the administrator verifies", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "match a name case-insensitively", behavior: "a differently-cased full name still resolves to the installed repository", layer: "unit" }
    it "matches a name whatever its case" do
      stub_github(repos: [github_repo("acme/Billing-Service")])

      expect(verify("ACME/billing-service")).to be_verified
    end

    # Asked of our own table before any network call: a user who has installed nothing has nothing
    # to ask GitHub about, and the answer is "install it", not "denied".
    # @intent: { entity: "InstallationRepositories", action: "offer the install fix", behavior: "a user with no installation gets :not_installed flagged install? so the suggested fix is installation", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "offer the authorize fix", behavior: "a nil session token gets :not_authorized flagged authorize? rather than install?", layer: "unit" }
    it "reports a session with no credential, and marks the fix as an authorization" do
      verdict = verify("acme/billing-service", user_token: nil)

      expect(verdict.status).to eq(:not_authorized)
      expect(verdict).to be_authorize
      expect(verdict).not_to be_install
    end

    # `install?` and `authorize?` are the predicates a form reads to decide between offering a
    # button and offering a field. Every other refusal is fixed on GitHub's configure page or not at
    # all, so offering either button for one would be offering a click that changes nothing.
    # @intent: { entity: "InstallationRepositories", action: "leave other refusals unfixable", behavior: "neither install? nor authorize? is true for any refusal other than the two they name", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "fail closed on outage", behavior: "an unavailable GitHub yields :unavailable instead of verifying by default", layer: "unit" }
    it "refuses while GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect(verify("acme/billing-service").status).to eq(:unavailable)
    end

    # A rate limit is the one refusal that genuinely clears by waiting, so it says so rather than
    # being folded into the outage that also says "try again" but never resolves.
    # @intent: { entity: "InstallationRepositories", action: "name a rate limit", behavior: "a rate-limited 403 is reported as :rate_limited with a message saying so, distinct from an outage", layer: "unit" }
    it "names a rate limit rather than reporting it as an outage" do
      stub_github(forbidden: :rate_limited)

      verdict = verify("acme/billing-service")

      expect(verdict.status).to eq(:rate_limited)
      expect(verdict.message).to include("rate limit")
    end

    # @intent: { entity: "InstallationRepositories", action: "report a plain 403 as outage", behavior: "a 403 that is not rate limiting surfaces as :unavailable", layer: "unit" }
    it "reports a refusal that is not a rate limit as an outage the user cannot act on" do
      stub_github(forbidden: :refused)

      expect(verify("acme/billing-service").status).to eq(:unavailable)
    end
  end

  describe ".verify_batch" do
    # @intent: { entity: "InstallationRepositories", action: "answer one verdict per name", behavior: "each submitted name gets one verdict positioned in submission order and duplicates are answered consistently", layer: "unit" }
    it "answers one verdict per name, in the order given" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/readonly", admin: false)])

      expect(statuses("acme/api", "ghost/repo", "acme/readonly", "acme/api"))
        .to eq(%i[verified not_in_installation not_administered verified])
    end

    # The answer is a set test over a listing SpecGuard has to fetch either way, so twenty names
    # cost what one name costs. A per-name round trip would be twenty sequential calls before the
    # first row is saved.
    # @intent: { entity: "InstallationRepositories", action: "read the listing once per batch", behavior: "any number of submitted names triggers exactly one repositories call", layer: "unit" }
    it "asks GitHub once however many names were submitted" do
      fake = stub_github(repos: [github_repo("acme/api")])

      described_class.verify_batch(user: user, user_token: token,
                                   full_names: %w[acme/api acme/web beta/x ghost/y])

      expect(fake.calls_to(:repositories)).to eq(1)
    end

    # @intent: { entity: "InstallationRepositories", action: "ignore blank entries", behavior: "blank and nil entries produce no verdicts and an all-blank batch returns an empty list", layer: "unit" }
    it "ignores blank entries and answers nothing for an empty submission" do
      stub_github(repos: [github_repo("acme/api")])

      expect(described_class.verify_batch(user: user, user_token: token, full_names: [" ", nil])).to eq([])
      expect(statuses("acme/api", "")).to eq(%i[verified])
    end

    # @intent: { entity: "InstallationRepositories", action: "answer not installed per batch", behavior: "every name answers :not_installed when the App is not installed", layer: "unit" }
    it "gives every name the same answer when the App is not installed" do
      uninstall_github_app(user)

      expect(statuses("acme/api", "acme/web")).to eq(%i[not_installed not_installed])
    end

    # @intent: { entity: "InstallationRepositories", action: "answer not authorized per batch", behavior: "every name answers :not_authorized when the session holds no credential", layer: "unit" }
    it "gives every name the same answer when the session holds no credential" do
      expect(statuses("acme/api", "acme/web", user_token: nil)).to eq(%i[not_authorized not_authorized])
    end

    # Nothing is registered on a GitHub outage, for the reason the single path states: verifying by
    # default during an outage reopens the gap intermittently, which is worse than the gap itself.
    # @intent: { entity: "InstallationRepositories", action: "fail a batch closed", behavior: "every name answers :unavailable when the listing could not be read", layer: "unit" }
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
    # @intent: { entity: "InstallationRepositories", action: "refuse absence under truncation", behavior: "a name missing from a truncated listing is refused with :unavailable and no per-name fallback request is made", layer: "unit" }
    it "refuses an absent name rather than asking about it individually" do
      fake = stub_github(repos: [github_repo("acme/api")], truncated: true)

      expect(verify("ghost/repo").status).to eq(:unavailable)
      expect(fake.calls_to(:repositories)).to eq(1)
    end

    # A name that IS in the part that was read is still answered from it — truncation makes absence
    # meaningless, not presence.
    # @intent: { entity: "InstallationRepositories", action: "verify presence under truncation", behavior: "a name the truncated reading did contain is still verified from that partial read", layer: "unit" }
    it "still verifies a name the incomplete reading did contain" do
      stub_github(repos: [github_repo("acme/api")], truncated: true)

      expect(verify("acme/api")).to be_verified
    end

    # @intent: { entity: "InstallationRepositories", action: "report the recorded failure", behavior: "under truncation the actual recorded failure (:rate_limited) is reported rather than an invented refusal", layer: "unit" }
    it "reports the recorded failure rather than inventing a refusal" do
      stub_github(forbidden: :rate_limited)

      expect(verify("acme/api").status).to eq(:rate_limited)
    end

    # @intent: { entity: "InstallationRepositories", action: "read once for a truncated batch", behavior: "a partially answerable batch makes exactly one repositories call and answers absent names :unavailable", layer: "unit" }
    it "asks GitHub once for a whole batch it cannot fully answer" do
      fake = stub_github(repos: [github_repo("acme/api")], truncated: true)

      statuses = described_class.verify_batch(user: user, user_token: token,
                                              full_names: %w[acme/api ghost/one ghost/two]).map(&:status)

      expect(statuses).to eq(%i[verified unavailable unavailable])
      expect(fake.calls_to(:repositories)).to eq(1)
    end
  end
end
