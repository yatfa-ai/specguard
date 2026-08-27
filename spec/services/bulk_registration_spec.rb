# frozen_string_literal: true

require "rails_helper"

# Registering many repositories in one action.
#
# The contract under test is not "it registers things" — it is that EVERY submitted name comes back
# answered. A batch is not a transaction: a user turning SpecGuard on across an organization will
# routinely have three repositories already registered and one the GitHub App was never installed
# on, and refusing to do nineteen things because of one is not a feature. So the examples below are
# mostly about the arithmetic of the result: what was registered, what was skipped, and whether the
# two still add up to what was submitted.
#
# Ownership here takes two things — the repository is in one of the user's GitHub App installations
# AND GitHub names this user an administrator of it (see `InstallationRepositories`) — so the
# repositories named in `stub_github(repos: […])` are not scenery: they ARE the set that may be
# registered, and `github_repo(…, admin: false)` is the one a user can see and cannot register.
# A name outside the list is a name nobody handed to SpecGuard, and the fake refuses it exactly as
# GitHub would refuse a read made with this user's own credential.
RSpec.describe BulkRegistration do
  let(:user) { create_user }

  # `user_token` is what the ownership question is asked WITH — a credential that speaks for this
  # user rather than for the App — so a batch is not registerable without one. The
  # `not_authorized:` shape is a spec about a session that has none.
  def register(*names, user_token: "ghu_octocat")
    described_class.call(user: user, full_names: names.flatten, user_token: user_token)
  end

  def outcome_for(result, full_name)
    result.outcomes.find { |o| o.full_name == full_name }
  end

  describe "the happy path" do
    it "registers every repository the SpecGuard GitHub App is installed on" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")])

      expect { @result = register("acme/api", "acme/web") }.to change(Repository, :count).by(2)

      expect(@result.registered_count).to eq(2)
      expect(@result.skipped_count).to eq(0)
      expect(user.repositories.pluck(:github_full_name)).to match_array(%w[acme/api acme/web])
    end

    it "hands back the row it created, so a summary can link to it" do
      stub_github(repos: [github_repo("acme/api")])

      outcome = register("acme/api").registered.first

      expect(outcome.repository).to be_a(Repository)
      expect(outcome.repository.github_full_name).to eq("acme/api")
    end
  end

  # The arithmetic. Nothing may be dropped on the floor, because a summary a reader cannot check is
  # the dishonest "registered 20!" this whole slice exists to avoid.
  describe "answering for every submitted name" do
    # Two of these are refused for what used to be two different reasons — one the installation does
    # not cover, one GitHub has never heard of — and they come back as ONE status. An installation
    # credential is answered 404 for anything outside its own installation, so SpecGuard cannot tell
    # "you did not select it" from "it does not exist", and the result says the one thing it knows
    # rather than inventing the distinction.
    it "returns one outcome per submitted repository, whatever happened to each" do
      create_repository(user: create_user(github_uid: "9", github_handle: "someone"),
                        github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/taken")])

      result = register("acme/api", "acme/theirs", "acme/taken", "ghost/repo", "not-a-slug")

      expect(result.total_count).to eq(5)
      expect(result.registered_count + result.skipped_count).to eq(5)
      expect(result.outcomes.map(&:status))
        .to eq(%i[registered not_in_installation already_registered not_in_installation invalid])
    end

    it "registers what it can and skips the rest, rather than failing the batch" do
      stub_github(repos: [github_repo("acme/api")])

      expect { register("acme/api", "acme/theirs") }.to change(Repository, :count).by(1)
    end
  end

  describe "already registered" do
    # Not an error. "Register all of them" is the point of the feature, and on the second run most
    # of them are already registered.
    it "skips a repository this user already registered, and links to it" do
      existing = create_repository(user: user, github_full_name: "acme/api")
      stub_github(repos: [github_repo("acme/api")])

      expect { @result = register("acme/api") }.not_to change(Repository, :count)

      outcome = @result.skipped.first
      expect(outcome.status).to eq(:already_registered)
      expect(outcome.repository).to eq(existing)
      expect(outcome.sentence).to eq("acme/api is already registered in SpecGuard.")
    end

    it "skips a repository shared with this user, and links to it" do
      owner = create_user(github_uid: "9", github_handle: "owner")
      shared = create_repository(user: owner, github_full_name: "acme/api")
      create_membership(repository: shared, user: user)
      stub_github(repos: [github_repo("acme/api")])

      expect(register("acme/api").skipped.first.repository).to eq(shared)
    end

    # "Already registered" is all this page may honestly say about somebody else's repository. A
    # link to a 403 says more than that.
    it "does not link to a repository this user may not open" do
      create_repository(user: create_user(github_uid: "9", github_handle: "stranger"),
                        github_full_name: "acme/api")
      stub_github(repos: [github_repo("acme/api")])

      outcome = register("acme/api").skipped.first

      expect(outcome.status).to eq(:already_registered)
      expect(outcome.repository).to be_nil
    end

    # The uniqueness rule that produced this skip is case-insensitive, so the lookup explaining it
    # has to be too — otherwise the summary fails to find the very row it is describing.
    it "finds the existing row whatever its case" do
      existing = create_repository(user: user, github_full_name: "Acme/API")
      stub_github(repos: [github_repo("acme/api")])

      expect(register("acme/api").skipped.first.repository).to eq(existing)
    end

    # A repository registered before it was dropped from the installation is still registered.
    # Reporting it as "not connected to the App" would send the user to GitHub to fix something that
    # is not the problem — and it must not cost a GitHub question either.
    it "reports already-registered before membership, and does not ask GitHub about it" do
      create_repository(user: user, github_full_name: "acme/api")
      fake = stub_github(repos: [])

      expect(register("acme/api").skipped.first.status).to eq(:already_registered)
      expect(fake.calls).to be_empty
    end
  end

  describe "membership is verified here, not inherited from the page" do
    # The tick boxes are client-controlled. A submitted name the page never offered is an ASSERTION,
    # and it is refused by asking GitHub which repositories the App is actually installed on.
    it "refuses a repository outside the user's installation, however it was submitted" do
      stub_github(repos: [github_repo("acme/api")])

      expect { @result = register("someone-else/theirs") }.not_to change(Repository, :count)

      expect(@result.skipped.first.status).to eq(:not_in_installation)
      expect(@result.skipped.first.sentence)
        .to include("is not one of the repositories the SpecGuard GitHub App is installed on")
    end

    # The same refusal, deliberately. There is no separate "GitHub has never heard of it" answer to
    # give: the installation credential sees nothing outside the installation, so a repository that
    # does not exist and one that was never selected are the same 404 and get the same sentence —
    # one that tells the user to add it on GitHub rather than claiming it is not there.
    it "refuses a repository GitHub has never heard of with that same answer" do
      stub_github(repos: [])

      expect { @result = register("ghost/repo") }.not_to change(Repository, :count)

      expect(@result.skipped.first.status).to eq(:not_in_installation)
    end

    # Fails closed, for the whole batch. Verifying by default during an outage reopens the squatting
    # gap intermittently, which is a worse property than the gap itself.
    it "registers nothing at all while GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect { @result = register("acme/api", "acme/web") }.not_to change(Repository, :count)

      expect(@result.skipped.map(&:status)).to eq(%i[unavailable unavailable])
    end

    # A token GitHub rejects mid-batch is a session that has run out, not an outage and not a
    # missing installation: this user has installed the App and installing it again fixes nothing.
    # It fails closed, and the summary offers the button that does fix it.
    it "registers nothing when GitHub rejects the user's credential" do
      stub_github(unauthorized: true)

      expect { @result = register("acme/api") }.not_to change(Repository, :count)

      expect(@result.skipped.first.status).to eq(:not_authorized)
      expect(@result).to be_authorize
      expect(@result).not_to be_install
    end

    # The same refusal one step earlier, and the ordinary one: a returning user's first batch of the
    # session, before anything has asked GitHub who they are. Nothing is registered on a question
    # that was never actually asked.
    it "registers nothing when the session holds no credential at all" do
      expect { @result = register("acme/api", user_token: nil) }.not_to change(Repository, :count)

      expect(@result.skipped.first.status).to eq(:not_authorized)
      expect(@result).to be_authorize
    end

    # The gap the audit found, at the layer that carries it. A bulk submission is checkboxes the
    # browser controls, so a name the picker never offered can arrive here — and "in the
    # installation" is not the same as "yours". A read-only member of an organization can see every
    # repository their employer connected; none of them is theirs to register.
    it "refuses a repository in the installation that this user does not administer" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/vault", admin: false)])

      expect { @result = register("acme/api", "acme/vault") }.to change(Repository, :count).by(1)

      expect(@result.registered.map(&:full_name)).to eq(%w[acme/api])
      expect(@result.skipped.map(&:status)).to eq(%i[not_administered])
      expect(@result.skipped.first.sentence).to include("does not list you as an administrator")
    end

    it "registers nothing when the user has not installed the App" do
      uninstall_github_app(user)

      expect { @result = register("acme/api") }.not_to change(Repository, :count)

      expect(@result.skipped.first.status).to eq(:not_installed)
      expect(@result).to be_install
    end

    # One listing for the batch, and it stays one — see `InstallationRepositories.verify_batch`.
    # Membership is a set test over a listing SpecGuard has to fetch anyway, so fifteen names cost
    # what one costs; a per-name question would be fifteen sequential round trips before the first
    # row is saved.
    it "asks GitHub once however many repositories were submitted" do
      fake = stub_github(repos: Array.new(15) { |i| github_repo("acme/r#{i}") })

      register(Array.new(15) { |i| "acme/r#{i}" })

      expect(fake.calls_to(:repositories)).to eq(1)
      expect(fake.calls_to(:repository)).to eq(0)
    end
  end

  describe "the record's own rules run before GitHub is asked" do
    it "refuses a name that is not org/repo without a GitHub round trip" do
      fake = stub_github(repos: [github_repo("acme/api")])

      expect { @result = register("nonsense") }.not_to change(Repository, :count)

      expect(@result.skipped.first.status).to eq(:invalid)
      expect(@result.skipped.first.sentence).to include("must look like org/repo")
      expect(fake.calls).to be_empty
    end

    # `valid?` is what runs `normalize_full_name`, so the name looked for in the installation — and
    # the one the summary names — is the value that would actually be stored.
    it "asks GitHub about the normalized name, not whatever was pasted" do
      fake = stub_github(repos: [github_repo("acme/api")])

      result = register("https://github.com/acme/api.git")

      expect(result.registered.first.full_name).to eq("acme/api")
      expect(fake.calls).to include([:repositories])
      expect(Repository.last.github_full_name).to eq("acme/api")
    end
  end

  describe "the shape of the submission" do
    it "registers nothing for an empty batch, and asks GitHub nothing" do
      fake = stub_github

      result = register

      expect(result.total_count).to eq(0)
      expect(fake.calls).to be_empty
    end

    it "ignores blank entries" do
      stub_github(repos: [github_repo("acme/api")])

      expect(register("acme/api", "", "  ").total_count).to eq(1)
    end

    # The same repository named twice would otherwise register once and report ITSELF as already
    # registered — a true sentence about a batch nobody submitted.
    it "deduplicates the same repository named twice, case-insensitively" do
      stub_github(repos: [github_repo("acme/api")])

      expect { @result = register("acme/api", "ACME/API") }.to change(Repository, :count).by(1)

      expect(@result.total_count).to eq(1)
    end
  end

  describe "the summary a caller renders" do
    it "groups skips by reason, in a stable order, dropping empty groups" do
      create_repository(user: user, github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/taken")])

      groups = register("acme/theirs", "acme/taken", "nope").skipped_groups

      expect(groups.map(&:first)).to eq(%i[already_registered not_in_installation invalid])
      expect(groups.map(&:second)).to eq(["Already registered",
                                          "Not connected to the SpecGuard GitHub App",
                                          "Not a valid repository name"])
      expect(groups.map { |_, _, rows| rows.length }).to eq([1, 1, 1])
    end

    # A batch skipped because the App is not installed is not something a re-run fixes, so the
    # summary has to be able to offer the install button instead of only counting.
    it "reports when the fix on offer is installing the App rather than a different selection" do
      uninstall_github_app(user)

      expect(register("acme/api")).to be_install
    end

    # The App IS installed and this repository is not in it. The fix is on GitHub's own picker, so
    # offering "install the App" here would send the user through a flow they have already done.
    it "does not offer the install button for a refusal installing cannot fix" do
      stub_github(repos: [github_repo("acme/api")])

      expect(register("acme/theirs")).not_to be_install
    end

    # Nor for a refusal that is not the user's to fix at all: rejected App credentials are an
    # operator's misconfiguration, and the button would be advice that cannot work.
    it "does not offer the install button when GitHub rejected the App's credentials" do
      stub_github(unauthorized: true)

      expect(register("acme/api")).not_to be_install
    end

    # SPGD-833. The third control of the same family, and the skip whose own sentence has always
    # been an instruction to the reader ("Add it on GitHub, then pick it here.") with no way to
    # take it. The App is installed and the credential is fine, so neither `install?` nor
    # `authorize?` is true — this is the question that was missing between them.
    it "reports when the fix on offer is choosing more repositories on GitHub" do
      stub_github(repos: [github_repo("acme/api")])

      expect(register("acme/theirs")).to be_choose_repositories
    end

    # The deliberate exclusion, asserted rather than merely absent. `not_administered` is equally
    # terminal for a re-submission, but its fix belongs to somebody ELSE: the reader's selection on
    # GitHub is already correct, and sending them to change it would be sending them to fix
    # something that is not broken while what is actually in their way stays untouched.
    it "does not offer it for a repository the user does not administer" do
      stub_github(repos: [github_repo("acme/vault", admin: false)])

      result = register("acme/vault")

      expect(result.skipped.map(&:status)).to eq(%i[not_administered])
      expect(result).not_to be_choose_repositories
      expect(result.choose_repositories_names).to be_empty
    end

    # Nor for the skips that have their own controls, so this predicate cannot quietly become a
    # third panel on a page that already offers the right one.
    it "does not offer it when the App is not installed at all" do
      uninstall_github_app(user)

      expect(register("acme/api")).not_to be_choose_repositories
    end

    it "does not offer it when the session credential is dead" do
      stub_github(unauthorized: true)

      expect(register("acme/api")).not_to be_choose_repositories
    end
  end

  # SPGD-833. The names the "Choose repositories on GitHub" button carries back, and the third
  # list of the family `install_retryable_names` / `retryable_names` already belong to.
  describe "which names the choose-repositories control carries back" do
    # The narrowest of the three, and narrow because the TRIP is narrow: reopening GitHub's picker
    # for an installation that already exists changes the answer for exactly these names and for
    # nothing else. Every other skip on the page is untouched by it.
    it "carries only the not-in-installation names" do
      create_repository(user: user, github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/taken"),
                          github_repo("acme/vault", admin: false)])

      result = register("acme/api", "acme/theirs", "acme/ghost", "acme/taken", "acme/vault", "nope")

      expect(result.choose_repositories_names).to eq(%w[acme/theirs acme/ghost])
      # The controls this one must not become: neither of the other two lists claims these names,
      # because neither of those trips resolves them.
      expect(result.retryable_names).to be_empty
      expect(result.install_retryable_names).to be_empty
    end

    # Nothing that registered rides along — free from starting at `skipped`, and asserted because a
    # carried batch is the failed remainder rather than a re-run of the submission.
    it "carries nothing that registered" do
      stub_github(repos: [github_repo("acme/api")])

      result = register("acme/api", "acme/theirs")

      expect(result.registered.map(&:full_name)).to eq(%w[acme/api])
      expect(result.choose_repositories_names).to eq(%w[acme/theirs])
    end

    # A transient skip is not carried here even though it IS carried by the other two controls.
    # Coming back from GitHub's picker with a rate-limited name ticked would offer it as fixed by a
    # trip that could not have fixed it.
    it "does not carry a transiently-skipped name" do
      stub_github(unauthorized: true)

      result = register("acme/api")

      expect(result.choose_repositories_names).to be_empty
      expect(result.retryable_names).to eq(%w[acme/api])
    end
  end

  # SPGD-828. The summary's two FIX buttons carry the batch back to the picker the way "Try these
  # again" already does, and the two lists they carry are deliberately NOT the same list. This is
  # the service half of that: which names each button is owed.
  describe "which names each control carries back" do
    # The install button's list is WIDER than the retry button's by exactly the `not_installed`
    # names, and this is the case that proves the widening is load-bearing rather than cosmetic.
    # Installing the App is the trip that makes these registerable, so a list that omitted them
    # would carry back everything EXCEPT what the button just fixed — here, nothing at all.
    it "carries the not-installed names on the install control and nothing on the retry control" do
      uninstall_github_app(user)

      result = register("acme/api", "acme/web")

      expect(result.install_retryable_names).to eq(%w[acme/api acme/web])
      expect(result.retryable_names).to be_empty
    end

    # The other side of the same asymmetry, and the reason `retryable_names` must not simply become
    # the union: a re-submission genuinely does resolve these, so both controls owe them.
    it "carries a transiently-skipped name on both controls" do
      stub_github(unauthorized: true)

      result = register("acme/api")

      expect(result.retryable_names).to eq(%w[acme/api])
      expect(result.install_retryable_names).to eq(%w[acme/api])
    end

    # Neither list carries a terminal skip, because neither button resolves one: installing the App
    # does not un-register an already-registered repository or make an invalid name valid, and a
    # re-submission refuses both identically.
    it "carries no terminal skip on either control" do
      create_repository(user: user, github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/taken")])

      result = register("acme/taken", "acme/theirs", "nope")

      expect(result.retryable_names).to be_empty
      expect(result.install_retryable_names).to be_empty
    end

    # And nothing that REGISTERED is carried by either, which both readers get for free by starting
    # from `skipped` — a carried batch is the failed remainder, not a re-run of the submission.
    it "carries nothing that registered" do
      add_github_installation(user, installation_id: 6002, account_login: "globex")
      stub_github_per_installation do |id|
        FakeGithubApi.new(**(id == 6002 ? { unavailable: true } : { repos: [github_repo("acme/api")] }))
      end

      result = register("acme/api", "acme/web")

      expect(result.registered.map(&:full_name)).to eq(%w[acme/api])
      expect(result.retryable_names).to eq(%w[acme/web])
      expect(result.install_retryable_names).to eq(%w[acme/web])
    end

    # A Result assembled by hand, and deliberately so: `InstallationRepositories.verify_batch`
    # answers `:not_installed` for EVERY name or for none (it short-circuits the whole batch on
    # `sources.installed?`), so a result holding `:not_installed` ALONGSIDE a retryable skip cannot
    # currently be produced by the service at all.
    #
    # It is still what the reader has to be right about. `install?` and `retry?` are independent
    # questions asked by two independent `if`s in the summary, so the day a partially-installed
    # reading becomes reachable — a per-installation verdict, say — this reader must already carry
    # the union rather than quietly dropping one side. Pinning it here says which answer is
    # intended, at the layer that decides it, instead of leaving it to be discovered later.
    it "carries the union when a single batch holds both, and keeps the two lists apart" do
      outcomes = [BulkRegistration::Outcome.new(full_name: "acme/uninstalled", status: :not_installed),
                  BulkRegistration::Outcome.new(full_name: "acme/limited", status: :rate_limited),
                  BulkRegistration::Outcome.new(full_name: "acme/taken", status: :already_registered)]

      result = BulkRegistration::Result.new(outcomes: outcomes)

      expect(result).to be_install
      expect(result).to be_retry
      expect(result.install_retryable_names).to eq(%w[acme/uninstalled acme/limited])
      expect(result.retryable_names).to eq(%w[acme/limited])
      expect(result.install_retryable_names).not_to eq(result.retryable_names)
    end
  end

  # A second batch running concurrently is the realistic way this happens, and it must read as
  # "already registered" rather than as an exception escaping the action.
  describe "losing a race to another registration" do
    it "reports a repository the unique index rejected as already registered" do
      stub_github(repos: [github_repo("acme/api")])
      allow_any_instance_of(Repository).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

      result = register("acme/api")

      expect(result.skipped.first.status).to eq(:already_registered)
      expect(result.registered_count).to eq(0)
    end

    # SPGD-775 — the same condition, with NOTHING STUBBED ON `save`.
    #
    # The example above stubs `save` to raise, which pins the `rescue ActiveRecord::RecordNotUnique`
    # below it. That rescue is no longer the branch a real raced row takes: `Repository#save` now
    # contains the violation itself and returns `false`, so this service reaches
    # `elsif taken?(candidate.record)` instead — and `taken?` asks
    # `errors.of_kind?(:github_full_name, :taken)`, which is a TYPE test rather than a message test.
    #
    # That makes this example the one that can tell the two translations apart. A `Repository`
    # recording its refusal as the raw STRING "has already been taken" renders an identical sentence
    # everywhere a human looks, and still fails `of_kind?`, demoting this row from
    # `:already_registered` to `:invalid`. The stubbed example above cannot see that, because it
    # never lets the real `save` run — it would stay green through the regression.
    #
    # The race itself is simulated the honest way, by silencing the uniqueness validation, which is
    # exactly what it does on its own when it cannot see the winning row yet.
    it "reports a REAL raced row as already registered, not as invalid" do
      create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                        github_full_name: "acme/api")
      stub_github(repos: [github_repo("acme/api")])
      allow(uniqueness_validator(Repository)).to receive(:validate_each)

      result = register("acme/api")

      expect(result.registered_count).to eq(0)
      expect(result.skipped.first.status).to eq(:already_registered)
      expect(result.skipped.first.message).to eq(BulkRegistration::ALREADY_REGISTERED_MESSAGE)
    end
  end
end
