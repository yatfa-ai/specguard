# frozen_string_literal: true

require "rails_helper"

# SPGD-952 — the agent credential's own rules, before any HTTP exists: what a grant may contain,
# who may mint it, and when a token stops resolving.
RSpec.describe AgentApiKey do
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

  describe "#revoke!" do
    # Re-stamping on a replayed revoke is unobservable (the button is offered only on live keys),
    # so the assertion is that the state stays REVOKED — never that the stamp survives unchanged.
    it "stamps revoked_at, keeps the row, and stays revoked when revoked again" do
      key, _repository = owned_key

      key.revoke!
      key.revoke!

      expect(key.reload.revoked_at).to be_present
      expect(key).to be_revoked
      expect(AgentApiKey.exists?(key.id)).to be(true)
    end
  end

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
end
