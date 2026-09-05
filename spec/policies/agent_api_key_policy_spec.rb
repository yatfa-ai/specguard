# frozen_string_literal: true

require "rails_helper"

# SPGD-952 — the agent credential's half of the policy protocol `RepositoryAuthorization` asks.
# The person half is `RepositoryPolicy`'s spec; the rules that DIFFER here are the subject: the
# repository set is the boundary, `view` is implied by it, and owner-only stays owner-only.
RSpec.describe AgentApiKeyPolicy do
  let(:owner) { create_user(github_uid: "92001", github_handle: "minting-owner") }
  let(:repository) { create_repository(user: owner) }
  let(:granted_key) { create_agent_api_key(user: owner, repositories: [repository]) }

  def policy_for(key, repo = repository) = described_class.new(key, repo)

  describe "member?" do
    # @intent: { entity: "AgentApiKeyPolicy", action: "bound by the set", behavior: "a repository in the key's set reads as a member and one outside it does not, with no membership row anywhere", layer: "unit" }
    it "covers exactly the key's repository set" do
      expect(RepositoryMembership.count).to eq(0)

      expect(policy_for(granted_key)).to be_member

      other = create_repository(user: create_user(github_uid: "92002", github_handle: "else"),
                                github_full_name: "acme/elsewhere")
      expect(policy_for(granted_key, other)).not_to be_member
    end
  end

  describe "can?" do
    # @intent: { entity: "AgentApiKeyPolicy", action: "imply view from the set", behavior: "a read-only key can view a repository in its set without an explicit view permission", layer: "unit" }
    it "can view a granted repository with no permissions stored at all" do
      expect(granted_key.permissions).to eq([])

      expect(policy_for(granted_key)).to be_can(:view)
    end

    # @intent: { entity: "AgentApiKeyPolicy", action: "gate verbs on the permission set", behavior: "a capability passes exactly when the key stores its permission", layer: "unit" }
    it "honors stored permissions and refuses the absent ones" do
      key = create_agent_api_key(user: owner, repositories: [repository],
                                 permissions: ["members.manage"])
      policy = policy_for(key)

      expect(policy).to be_can(:members_manage)
      expect(policy).not_to be_can(:keys_manage)
      expect(policy).not_to be_can(:repo_delete)
    end

    # The wall, stated in RepositoryPolicy::OWNER_ONLY and held here: no agent key is ever the
    # owner, so the rename capability can never pass — whatever the permission array was tricked
    # into holding.
    # @intent: { entity: "AgentApiKeyPolicy", action: "keep owner-only shut", behavior: "the owner capability never passes for an agent key, even with every permission stored", layer: "unit" }
    it "never grants the owner capability" do
      key = create_agent_api_key(user: owner, repositories: [repository],
                                 permissions: RepositoryMembership::PERMISSIONS)

      expect(policy_for(key)).not_to be_can(:owner)
      expect(policy_for(key)).not_to be_owner
    end

    # @intent: { entity: "AgentApiKeyPolicy", action: "answer an unknown capability", behavior: "an unknown capability raises like the person policy does, failing on the first request rather than locking silently", layer: "unit" }
    it "raises on a capability that does not exist" do
      expect { policy_for(granted_key).can?(:nonsense) }
        .to raise_error(ArgumentError, /unknown repository capability/)
    end

    # The boundary discipline: permission in the array, repository OUT of the set — refused. The
    # fork's order matters and is the concern's to enforce; the policy just answers honestly.
    # @intent: { entity: "AgentApiKeyPolicy", action: "refuse outside the set", behavior: "a permission held but outside the key's repository set reads as neither member nor capable", layer: "unit" }
    it "is not capable of anything on a repository outside the set" do
      other = create_repository(user: create_user(github_uid: "92003", github_handle: "else"),
                                github_full_name: "acme/elsewhere")
      key = create_agent_api_key(user: owner, repositories: [repository],
                                 permissions: ["members.manage"])

      policy = policy_for(key, other)

      expect(policy).not_to be_member
      expect(policy).not_to be_can(:members_manage)
      expect(policy).not_to be_can(:view)
    end
  end
end
