# frozen_string_literal: true

require "rails_helper"

# SPGD-952 — the agent credential's own rules, before any HTTP exists: what a grant may contain,
# who may mint it, and when a token stops resolving.
RSpec.describe AgentApiKey do
  include ActiveSupport::Testing::TimeHelpers

  # The ordinary mint: a person, one repository they own, a key over it. Most examples need all
  # three bound to the same person — the model's reachability validation is the reason a key and
  # its repository cannot be built from two independent default users.
  def owned_key(permissions: [], name: "Agent key")
    user = create_user
    repository = create_repository(user: user)
    [create_agent_api_key(user: user, repositories: [repository], permissions: permissions,
                          name: name), repository]
  end

  describe "validations" do
    it "requires a name and an owner" do
      key = AgentApiKey.new

      expect(key).not_to be_valid
      expect(key.errors).to include(:name)
      expect(key.errors).to include(:user)
    end

    # A NUL in `name` is refused here rather than at INSERT, where Postgres raises on the
    # character and the mint surfaces as a 500 — the same rule `Repository` states for
    # `github_full_name`.
    it "refuses a name containing a NUL character" do
      user = create_user
      key = AgentApiKey.new(user: user, repository_ids: [create_repository(user: user).id],
                            name: "CI\u0000x")

      expect(key).not_to be_valid
      expect(key.errors).to include(:name)
    end

    # SPGD-1878: an over-budget `name` is refused, not truncated — the same refuse-don't-coerce
    # shape as the NUL refusal above, with the number `NAME_MAX_LENGTH`'s comment derives from
    # `ApiKey::NAME_MAX_LENGTH`'s session-cookie measurement.
    # @intent: { entity: "AgentApiKey", action: "refuse an over-length name", behavior: "a key built with a name one character past NAME_MAX_LENGTH is invalid with an error on :name, so an over-budget mint is refused by validation instead of committing a row whose reveal flash would overflow the session cookie", layer: "unit" }
    it "refuses a name longer than NAME_MAX_LENGTH" do
      user = create_user
      key = AgentApiKey.new(user: user, repository_ids: [create_repository(user: user).id],
                            name: "x" * (described_class::NAME_MAX_LENGTH + 1))

      expect(key).not_to be_valid
      expect(key.errors).to include(:name)
    end

    # The boundary the refusal above implies: exactly at the cap the name is valid, so the cap
    # refuses strictly past itself and no name a form could legitimately send is over-refused.
    # @intent: { entity: "AgentApiKey", action: "accept a name at the cap", behavior: "a key built with a name of exactly NAME_MAX_LENGTH characters is valid, so the cap refuses strictly past itself", layer: "unit" }
    it "accepts a name of exactly NAME_MAX_LENGTH characters" do
      user = create_user
      key = AgentApiKey.new(user: user, repository_ids: [create_repository(user: user).id],
                            name: "x" * described_class::NAME_MAX_LENGTH)

      expect(key).to be_valid
    end

    it "requires at least one repository" do
      key = AgentApiKey.new(name: "x", user: create_user, repository_ids: [])

      expect(key).not_to be_valid
      expect(key.errors[:repository_ids].join).to include("at least one repository")
    end

    it "refuses a permission outside the membership vocabulary" do
      key, _repository = owned_key
      key.permissions = ["repo.own"]

      expect(key).not_to be_valid
      expect(key.errors[:permissions].join).to include("repo.own")
    end

    it "refuses a repository the owner cannot open" do
      repository = create_repository(user: create_user(github_uid: "2002", github_handle: "other"))
      key = AgentApiKey.new(name: "x", user: create_user,
                            repository_ids: [repository.id], permissions: [])

      expect(key).not_to be_valid
      expect(key.errors[:repository_ids].join).to include("cannot open")
    end

    # THE MIRROR THE TICKET NAMES: `RepositoryMembership#grantor_holds_every_granted_permission`
    # with the minting person in the grantor's seat. A person who is only a MEMBER of somebody
    # else's repository may mint an agent key over it only within what their own membership may
    # grant — bounded by `RepositoryPolicy#grantable_permissions`, not re-derived here.
    it "refuses a permission the owner does not hold on a member-shared repository, naming it" do
      owner = create_user(github_uid: "2003", github_handle: "repo-owner")
      repository = create_repository(user: owner)
      member = create_user(github_uid: "2004", github_handle: "member")
      create_membership(repository: repository, user: member, permissions: ["view"])

      key = AgentApiKey.new(name: "x", user: member, repository_ids: [repository.id],
                            permissions: ["members.manage"])

      expect(key).not_to be_valid
      expect(key.errors[:permissions].join).to include("members.manage on #{repository.github_full_name}")
    end

    it "accepts a permission set within what a member-owner may grant" do
      owner = create_user(github_uid: "2005", github_handle: "repo-owner")
      repository = create_repository(user: owner)
      member = create_user(github_uid: "2006", github_handle: "delegate")
      create_membership(repository: repository, user: member, permissions: %w[view keys.manage])

      key = AgentApiKey.new(name: "x", user: member, repository_ids: [repository.id],
                            permissions: ["keys.manage"])

      expect(key).to be_valid
    end

    it "accepts an empty permission set — the read-only grant — on repositories the owner owns" do
      key, _repository = owned_key(permissions: [])

      expect(key.reload.permissions).to eq([])
    end

    it "normalizes whitespace, blanks and duplicates out of both grant arrays" do
      key, _repository = owned_key
      key.assign_attributes(permissions: [" view ", "", "view", "keys.manage "])

      key.valid?

      expect(key.permissions).to eq(%w[view keys.manage])
    end

    it "coerces and dedupes repository ids" do
      key, repository = owned_key
      key.assign_attributes(repository_ids: [repository.id.to_s, repository.id, ""])

      key.valid?

      expect(key.repository_ids).to eq([repository.id])
    end
  end

  describe ".authenticate" do
    it "resolves a live token to its key" do
      key, _repository = owned_key

      expect(AgentApiKey.authenticate(key.raw_token)).to eq(key)
    end

    it "answers nil for a blank token" do
      expect(AgentApiKey.authenticate("")).to be_nil
    end

    # The security half of retirement: `revoke!` keeps the row, so the filter has to keep the
    # row from resolving.
    it "never resolves a revoked token" do
      key, _repository = owned_key
      key.revoke!

      expect(AgentApiKey.authenticate(key.raw_token)).to be_nil
      expect(AgentApiKey.revoked.exists?(key.id)).to be(true)
    end

    # The offboarding cut `UserApiKey.authenticate` established: an archived owner's credential
    # is the offboarding control's blind spot, so the cut runs at the resolution site.
    it "stops resolving when the owner is archived" do
      key, _repository = owned_key
      key.user.update!(archived_at: Time.current)

      expect(AgentApiKey.authenticate(key.raw_token)).to be_nil
    end
  end

  # SPGD-991 ported `ApiKey`'s refusal evidence pair here; the retirement contract it belongs to
  # (scopes, first-revocation-wins, the refusal pair) is now shared with the other key models and
  # pinned once for each of them in `spec/support/shared_examples/retirable_credential.rb`. The
  # builder shares ONE owner and repository across calls (`owned_key` makes a fresh default user
  # each time, and the group builds more than one key per example).
  let(:retirement_owner) { create_user }
  let(:retirement_repository) { create_repository(user: retirement_owner) }
  it_behaves_like "a retirable credential",
                  build: -> { create_agent_api_key(user: retirement_owner, repositories: [retirement_repository]) }

  describe "#token_hint" do
    it "carries this class's prefix and the digest tail" do
      key, _repository = owned_key

      expect(key.token_hint).to eq("sga_…#{key.token_digest.last(6)}")
    end
  end

  describe "#repositories and #covers?" do
    it "resolves exactly the granted set, and covers nothing outside it" do
      key, mine = owned_key
      other = create_repository(user: create_user(github_uid: "3002", github_handle: "other"),
                                github_full_name: "other/owned")

      expect(key.repositories).to contain_exactly(mine)
      expect(key.covers?(mine)).to be(true)
      expect(key.covers?(other)).to be(false)
    end

    it "answers covers? false for a nil repository" do
      key, _repository = owned_key

      expect(key.covers?(nil)).to be(false)
    end
  end

  # The SQL half of `covers?` (SPGD-989) — the listing boundary a repository-side reader asks.
  # Kept beside `#covers?` because the two are one question in two media, and a change to one
  # without the other is exactly the drift this pair of describes makes visible.
  describe ".covering" do
    it "selects exactly the rows whose stored set names the repository" do
      key, mine = owned_key
      other = create_repository(user: create_user(github_uid: "3003", github_handle: "other"),
                                github_full_name: "other/owned")
      stranger = create_agent_api_key(user: other.user, repositories: [other], name: "Elsewhere")

      expect(AgentApiKey.covering(mine)).to contain_exactly(key)
      expect(AgentApiKey.covering(other)).to contain_exactly(stranger)
    end

    # `covering` is a boundary read, not a retirement read: it deliberately does NOT filter
    # revoked rows, which is why every listing caller composes `live.covering` — the same
    # reader-picks-a-side rule the scopes' own comment states. Asserted so a later reader cannot
    # "simplify" the composition away without this failing.
    it "returns retired rows too, leaving the live side to the caller" do
      key, mine = owned_key
      key.revoke!

      expect(AgentApiKey.covering(mine)).to contain_exactly(key)
      expect(AgentApiKey.live.covering(mine)).to be_empty
    end
  end

  # The "could still authenticate" predicate, named once (SPGD-1963): the SQL restatement of
  # `authenticate`'s liveness and owner cuts plus `covering`'s boundary.
  describe ".authenticating_on" do
    it "selects only live, covering keys whose owner is active" do
      key, mine = owned_key
      revoked = create_agent_api_key(user: mine.user, repositories: [mine], name: "Revoked")
      revoked.revoke!
      other = create_repository(user: create_user(github_uid: "3003", github_handle: "other"),
                                github_full_name: "other/owned")
      create_agent_api_key(user: other.user, repositories: [other], name: "Elsewhere")

      expect(AgentApiKey.authenticating_on(mine)).to contain_exactly(key)
    end

    it "drops a key whose owner is archived, though the key is live and covering" do
      key, mine = owned_key
      expect(AgentApiKey.authenticating_on(mine)).to contain_exactly(key)

      key.user.update_columns(archived_at: Time.current)

      expect(AgentApiKey.live.covering(mine)).to contain_exactly(key)
      expect(AgentApiKey.authenticating_on(mine)).to be_empty
    end
  end

  # SPGD-2052 — the connection indicator's agent-key half (`RepositoryConnection.for`, and so
  # `credential_health.connection`) reads off this scope. It is `authenticating_on` plus the
  # `runs.ingest` grant; `.authenticating_on` above pins the first three limbs on the SIBLING
  # scope only, so these examples are what notice `carrying_ingest_for` being rewritten to
  # bypass it (to `live`, or to `live.covering`).
  describe ".carrying_ingest_for" do
    # @intent: { entity: "AgentApiKey", action: "select ingest carriers", behavior: "carrying_ingest_for(repository) contains a live key that covers the repository, holds runs.ingest and is owned by an active user", layer: "unit" }
    it "contains the live, covering, ingest-holding key of an active owner" do
      key, mine = owned_key(permissions: [RepositoryMembership::RUNS_INGEST])

      expect(AgentApiKey.carrying_ingest_for(mine)).to contain_exactly(key)
    end

    # @intent: { entity: "AgentApiKey", action: "exclude a non-covering key", behavior: "a key holding runs.ingest that covers only a second repository its owner has is not among carrying_ingest_for the first, so a key minted for a different repository cannot make this one read connected", layer: "unit" }
    it "excludes an ingest-holding key that covers only a different repository" do
      _key, mine = owned_key(permissions: [RepositoryMembership::RUNS_INGEST])
      second = create_repository(user: mine.user, github_full_name: "acme/second")
      elsewhere = create_agent_api_key(user: mine.user, repositories: [second], name: "Second only",
                                       permissions: [RepositoryMembership::RUNS_INGEST])

      expect(AgentApiKey.carrying_ingest_for(second)).to contain_exactly(elsewhere)
      expect(AgentApiKey.carrying_ingest_for(mine)).not_to include(elsewhere)
    end

    # @intent: { entity: "AgentApiKey", action: "exclude an archived owner's key", behavior: "a live, covering, ingest-holding key stops being among carrying_ingest_for once its owner is archived, because that token no longer authenticates", layer: "unit" }
    it "drops an ingest-holding key whose owner is archived" do
      key, mine = owned_key(permissions: [RepositoryMembership::RUNS_INGEST])
      expect(AgentApiKey.carrying_ingest_for(mine)).to contain_exactly(key)

      key.user.update_columns(archived_at: Time.current)

      expect(AgentApiKey.live.covering(mine)).to contain_exactly(key)
      expect(AgentApiKey.carrying_ingest_for(mine)).to be_empty
    end

    # @intent: { entity: "AgentApiKey", action: "exclude a key without the ingest grant", behavior: "a live, covering key of an active owner whose permissions are empty is not among carrying_ingest_for, so the permission limb is independent of the authentication limbs", layer: "unit" }
    it "excludes a live, covering key that does not hold runs.ingest" do
      key, mine = owned_key(permissions: [])

      expect(AgentApiKey.authenticating_on(mine)).to contain_exactly(key)
      expect(AgentApiKey.carrying_ingest_for(mine)).to be_empty
    end

    # @intent: { entity: "AgentApiKey", action: "exclude a revoked key", behavior: "a covering ingest-holding key of an active owner is not among carrying_ingest_for once revoked", layer: "unit" }
    it "excludes a revoked ingest-holding key" do
      key, mine = owned_key(permissions: [RepositoryMembership::RUNS_INGEST])
      key.revoke!

      expect(AgentApiKey.carrying_ingest_for(mine)).to be_empty
    end
  end
end
