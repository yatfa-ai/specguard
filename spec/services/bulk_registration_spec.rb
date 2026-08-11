# frozen_string_literal: true

require "rails_helper"

# Registering many repositories in one action.
#
# The contract under test is not "it registers things" — it is that EVERY submitted name comes back
# answered. A batch is not a transaction: a user turning SpecGuard on across an organization will
# routinely have three repositories already registered and one they do not administer, and refusing
# to do nineteen things because of one is not a feature. So the examples below are mostly about the
# arithmetic of the result: what was registered, what was skipped, and whether the two still add up
# to what was submitted.
RSpec.describe BulkRegistration do
  let(:user) { create_user }

  def register(*names)
    described_class.call(user: user, full_names: names.flatten)
  end

  def outcome_for(result, full_name)
    result.outcomes.find { |o| o.full_name == full_name }
  end

  describe "the happy path" do
    it "registers every repository GitHub says the user administers" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/web")], strict: true)

      expect { @result = register("acme/api", "acme/web") }.to change(Repository, :count).by(2)

      expect(@result.registered_count).to eq(2)
      expect(@result.skipped_count).to eq(0)
      expect(user.repositories.pluck(:github_full_name)).to match_array(%w[acme/api acme/web])
    end

    it "hands back the row it created, so a summary can link to it" do
      stub_github(repos: [github_repo("acme/api")], strict: true)

      outcome = register("acme/api").registered.first

      expect(outcome.repository).to be_a(Repository)
      expect(outcome.repository.github_full_name).to eq("acme/api")
    end
  end

  # The arithmetic. Nothing may be dropped on the floor, because a summary a reader cannot check is
  # the dishonest "registered 20!" this whole slice exists to avoid.
  describe "answering for every submitted name" do
    it "returns one outcome per submitted repository, whatever happened to each" do
      create_repository(user: create_user(github_uid: "9", github_handle: "someone"),
                        github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/theirs", admin: false),
                          github_repo("acme/taken")], strict: true)

      result = register("acme/api", "acme/theirs", "acme/taken", "ghost/repo", "not-a-slug")

      expect(result.total_count).to eq(5)
      expect(result.registered_count + result.skipped_count).to eq(5)
      expect(result.outcomes.map(&:status))
        .to eq(%i[registered not_admin already_registered not_found invalid])
    end

    it "registers what it can and skips the rest, rather than failing the batch" do
      stub_github(repos: [github_repo("acme/api"), github_repo("acme/theirs", admin: false)],
                  strict: true)

      expect { register("acme/api", "acme/theirs") }.to change(Repository, :count).by(1)
    end
  end

  describe "already registered" do
    # Not an error. "Register all of them" is the point of the feature, and on the second run most
    # of them are already registered.
    it "skips a repository this user already registered, and links to it" do
      existing = create_repository(user: user, github_full_name: "acme/api")
      stub_github(repos: [github_repo("acme/api")], strict: true)

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
      stub_github(repos: [github_repo("acme/api")], strict: true)

      expect(register("acme/api").skipped.first.repository).to eq(shared)
    end

    # "Already registered" is all this page may honestly say about somebody else's repository. A
    # link to a 403 says more than that.
    it "does not link to a repository this user may not open" do
      create_repository(user: create_user(github_uid: "9", github_handle: "stranger"),
                        github_full_name: "acme/api")
      stub_github(repos: [github_repo("acme/api")], strict: true)

      outcome = register("acme/api").skipped.first

      expect(outcome.status).to eq(:already_registered)
      expect(outcome.repository).to be_nil
    end

    # The uniqueness rule that produced this skip is case-insensitive, so the lookup explaining it
    # has to be too — otherwise the summary fails to find the very row it is describing.
    it "finds the existing row whatever its case" do
      existing = create_repository(user: user, github_full_name: "Acme/API")
      stub_github(repos: [github_repo("acme/api")], strict: true)

      expect(register("acme/api").skipped.first.repository).to eq(existing)
    end

    # An already-registered repository the user has since lost admin on is still already registered.
    # Reporting it as "not yours" would send them to fix something that is not the problem — and it
    # must not cost a GitHub question either.
    it "reports already-registered before ownership, and does not ask GitHub about it" do
      create_repository(user: user, github_full_name: "acme/api")
      fake = stub_github(repos: [github_repo("acme/api", admin: false)], strict: true)

      expect(register("acme/api").skipped.first.status).to eq(:already_registered)
      expect(fake.calls).to be_empty
    end
  end

  describe "ownership is verified here, not inherited from the page" do
    # The tick boxes are client-controlled. A submitted name the page never offered is an ASSERTION,
    # and it is refused.
    it "refuses a repository the user does not administer, however it was submitted" do
      stub_github(repos: [github_repo("someone-else/theirs", admin: false)], strict: true)

      expect { @result = register("someone-else/theirs") }.not_to change(Repository, :count)

      expect(@result.skipped.first.status).to eq(:not_admin)
      expect(@result.skipped.first.sentence).to include("is not a repository you administer on GitHub")
    end

    it "refuses a repository GitHub has never heard of" do
      stub_github(repos: [], strict: true)

      expect { register("ghost/repo") }.not_to change(Repository, :count)
    end

    # Fails closed, for the whole batch. Verifying by default during an outage reopens the squatting
    # gap intermittently, which is a worse property than the gap itself.
    it "registers nothing at all while GitHub cannot be reached" do
      stub_github(unavailable: true)

      expect { @result = register("acme/api", "acme/web") }.not_to change(Repository, :count)

      expect(@result.skipped.map(&:status)).to eq(%i[unavailable unavailable])
    end

    it "registers nothing when the user has not authorized repository access" do
      revoke_github_repository_access(user)

      expect { @result = register("acme/api") }.not_to change(Repository, :count)

      expect(@result.skipped.first.status).to eq(:not_connected)
      expect(@result).to be_reauthorize
    end

    # One GitHub call for the batch, and it stays one — see GithubOwnership.verify_batch.
    it "asks GitHub once however many repositories were submitted" do
      fake = stub_github(repos: Array.new(15) { |i| github_repo("acme/r#{i}") }, strict: true)

      register(Array.new(15) { |i| "acme/r#{i}" })

      expect(fake.calls_to(:repositories)).to eq(1)
      expect(fake.calls_to(:repository)).to eq(0)
    end
  end

  describe "the record's own rules run before GitHub is asked" do
    it "refuses a name that is not org/repo without a GitHub round trip" do
      fake = stub_github(repos: [github_repo("acme/api")], strict: true)

      expect { @result = register("nonsense") }.not_to change(Repository, :count)

      expect(@result.skipped.first.status).to eq(:invalid)
      expect(@result.skipped.first.sentence).to include("must look like org/repo")
      expect(fake.calls).to be_empty
    end

    # `valid?` is what runs `normalize_full_name`, so GitHub is asked about — and the summary names
    # — the value that would actually be stored.
    it "asks GitHub about the normalized name, not whatever was pasted" do
      fake = stub_github(repos: [github_repo("acme/api")], strict: true)

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
      stub_github(repos: [github_repo("acme/api")], strict: true)

      expect(register("acme/api", "", "  ").total_count).to eq(1)
    end

    # The same repository named twice would otherwise register once and report ITSELF as already
    # registered — a true sentence about a batch nobody submitted.
    it "deduplicates the same repository named twice, case-insensitively" do
      stub_github(repos: [github_repo("acme/api")], strict: true)

      expect { @result = register("acme/api", "ACME/API") }.to change(Repository, :count).by(1)

      expect(@result.total_count).to eq(1)
    end
  end

  describe "the summary a caller renders" do
    it "groups skips by reason, in a stable order, dropping empty groups" do
      create_repository(user: user, github_full_name: "acme/taken")
      stub_github(repos: [github_repo("acme/theirs", admin: false), github_repo("acme/taken")],
                  strict: true)

      groups = register("acme/theirs", "acme/taken", "nope").skipped_groups

      expect(groups.map(&:first)).to eq(%i[already_registered not_admin invalid])
      expect(groups.map(&:second)).to eq(["Already registered", "Not administered by you on GitHub",
                                          "Not a valid repository name"])
      expect(groups.map { |_, _, rows| rows.length }).to eq([1, 1, 1])
    end

    # A batch skipped for a dead token is not something a re-run fixes, so the summary has to be
    # able to offer the grant instead of only counting.
    it "reports when the fix on offer is a GitHub grant rather than a different selection" do
      stub_github(unauthorized: true)

      expect(register("acme/api")).to be_reauthorize
    end

    it "does not offer a grant for refusals a grant cannot fix" do
      stub_github(repos: [github_repo("acme/theirs", admin: false)], strict: true)

      expect(register("acme/theirs")).not_to be_reauthorize
    end
  end

  # A second batch running concurrently is the realistic way this happens, and it must read as
  # "already registered" rather than as an exception escaping the action.
  describe "losing a race to another registration" do
    it "reports a repository the unique index rejected as already registered" do
      stub_github(repos: [github_repo("acme/api")], strict: true)
      allow_any_instance_of(Repository).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

      result = register("acme/api")

      expect(result.skipped.first.status).to eq(:already_registered)
      expect(result.registered_count).to eq(0)
    end
  end
end
