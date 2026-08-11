# frozen_string_literal: true

require "rails_helper"

# `GithubOwnership.verify_batch` — the same ownership question asked of many repositories at once,
# for bulk registration.
#
# Two things are being pinned here and they pull in opposite directions. It has to be CHEAP: one
# GitHub round trip for the batch, not one per repository, or a twenty-repository organization is
# twenty sequential calls before the first row is saved. And it has to be exactly as STRICT as
# asking one at a time — a bulk path that trusts the browser, or that verifies-by-default when
# GitHub is unreachable, would reopen the squatting gap SPGD-354 closed by going around it.
RSpec.describe "GithubOwnership.verify_batch" do
  let(:user) { create_user }

  def verify(*names)
    GithubOwnership.verify_batch(user: user, full_names: names.flatten)
  end

  def statuses(*names)
    verify(*names).map(&:status)
  end

  it "verifies every repository GitHub reports the user as an admin of" do
    stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")], strict: true)

    expect(statuses("acme/api", "acme/web")).to eq(%i[verified verified])
  end

  # THE example. The browser is free to submit any name it likes — the tick boxes are
  # client-controlled — so a name the page never offered must be refused here, not registered.
  it "refuses a repository the user can see but does not administer" do
    stub_github(repos: [github_repo("acme/api"), github_repo("someone-else/theirs", admin: false)],
                strict: true)

    expect(statuses("acme/api", "someone-else/theirs")).to eq(%i[verified not_admin])
  end

  # Absent from a COMPLETE listing is GitHub's own answer about the world, not a limit of ours.
  it "refuses a repository absent from a complete listing without asking GitHub about it" do
    fake = stub_github(repos: [github_repo("acme/api")], strict: true)

    expect(statuses("acme/api", "ghost/repo")).to eq(%i[verified not_found])
    expect(fake.calls_to(:repository)).to eq(0)
  end

  # The cost half of the contract. Twenty repositories is ONE call, and it stays one.
  it "asks GitHub once for the whole batch" do
    fake = stub_github(repos: Array.new(20) { |i| github_repo("acme/repo-#{i}") }, strict: true)

    verify(Array.new(20) { |i| "acme/repo-#{i}" })

    expect(fake.calls_to(:repositories)).to eq(1)
    expect(fake.calls_to(:repository)).to eq(0)
  end

  it "answers in the order it was asked, one verdict per name" do
    stub_github(repos: [github_repo("acme/api"), github_repo("acme/web", admin: false)], strict: true)

    verdicts = verify("acme/web", "ghost/repo", "acme/api")

    expect(verdicts.map(&:full_name)).to eq(%w[acme/web ghost/repo acme/api])
    expect(verdicts.map(&:status)).to eq(%i[not_admin not_found verified])
  end

  # GitHub names are case-insensitive, and a name may arrive here having been round-tripped through
  # a form. Matching case-sensitively would refuse a repository the user genuinely administers.
  it "matches the listing case-insensitively" do
    stub_github(repos: [github_repo("Acme/API")], strict: true)

    expect(statuses("acme/api")).to eq(%i[verified])
  end

  describe "the truncation fallback" do
    # `MAX_PAGES` bounds the listing, so absent-from-a-truncated-listing means only that we stopped
    # reading. Refusing on that would be refusing a repository for a property of our own page walk.
    it "asks GitHub about a name the truncated listing did not reach" do
      fake = stub_github(repos: [github_repo("acme/api")], truncated: true)

      expect(statuses("acme/api", "acme/beyond-the-cap")).to eq(%i[verified verified])
      expect(fake.calls).to include([:repository, "acme/beyond-the-cap"])
    end

    # The fallback must not become a way around verification: the individually-asked repository is
    # held to exactly the same admin test.
    it "still refuses a fallback repository the user does not administer" do
      stub_github(repos: [github_repo("acme/theirs", admin: false)], truncated: true, strict: true)

      expect(statuses("acme/theirs")).to eq(%i[not_admin])
    end

    it "does not fall back for names the truncated listing did reach" do
      fake = stub_github(repos: [github_repo("acme/api")], truncated: true)

      verify("acme/api")

      expect(fake.calls_to(:repository)).to eq(0)
    end
  end

  describe "failing closed" do
    # An outage that verified by default would reopen the gap on every GitHub 500 — which is worse
    # than the gap itself, because it is intermittent. Nothing in the batch passes.
    it "refuses the whole batch when GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect(statuses("acme/api", "acme/web")).to eq(%i[unavailable unavailable])
    end

    it "refuses the whole batch when the token has been rejected" do
      stub_github(unauthorized: true)

      expect(statuses("acme/api", "acme/web")).to eq(%i[token_rejected token_rejected])
    end

    # The three 403s have three unrelated remedies, and a batch must keep them apart for exactly the
    # reason a single registration does: telling an SSO-blocked user to "try again shortly" is
    # telling them to retry forever.
    it "keeps the three refusals GitHub answers 403 for apart" do
      { sso_required: :sso_required, rate_limited: :rate_limited,
        insufficient_scope: :scope_too_narrow }.each do |reason, status|
        stub_github(forbidden: reason)

        expect(statuses("acme/api")).to eq([status]), "expected #{reason} to become #{status}"
      end
    end

    # Asked of the stored grant, before any network call — so it costs no round trip, and the answer
    # is "authorize", not "denied".
    it "answers not_connected for every name, without calling GitHub, when no token is stored" do
      revoke_github_repository_access(user)
      fake = stub_github

      expect(statuses("acme/api", "acme/web")).to eq(%i[not_connected not_connected])
      expect(fake.calls).to be_empty
    end

    it "answers not_connected when the granted scopes cannot read repositories" do
      narrow_github_scope(user)
      fake = stub_github

      expect(statuses("acme/api")).to eq(%i[not_connected])
      expect(fake.calls).to be_empty
    end
  end

  it "asks GitHub nothing for an empty batch" do
    fake = stub_github

    expect(verify).to eq([])
    expect(fake.calls).to be_empty
  end

  it "ignores blank names rather than asking GitHub about them" do
    stub_github(repos: [github_repo("acme/api")], strict: true)

    expect(verify("acme/api", "", "   ").map(&:full_name)).to eq(%w[acme/api])
  end

  # The messages are the whole point of a Verdict over a boolean, and a bulk skip has to show the
  # same sentence a single registration would have shown for the same refusal — the two are read
  # side by side.
  it "carries the same message a single verification would have carried" do
    stub_github(repos: [github_repo("acme/theirs", admin: false)], strict: true)

    batch = verify("acme/theirs").first
    single = GithubOwnership.verify(user: user, full_name: "acme/theirs")

    expect(batch.message).to eq(single.message)
    expect(batch.status).to eq(single.status)
  end
end
