# frozen_string_literal: true

require "rails_helper"

RSpec.describe RepositoryPolicy do
  let(:owner) { create_user }
  let(:repository) { create_repository(user: owner) }
  let(:teammate) { create_user(github_uid: "9999", github_handle: "someone-else") }
  let(:stranger) { create_user(github_uid: "7777", github_handle: "nobody") }

  def policy_for(user) = described_class.new(user, repository)

  describe "the owner" do
    # @intent: { entity: "RepositoryPolicy", action: "grant owner capabilities", behavior: "the owner holds every declared capability with no membership row in the table", layer: "unit" }
    it "holds every capability without a membership row" do
      expect(RepositoryMembership.count).to eq(0)

      described_class::CAPABILITIES.each_key do |capability|
        expect(policy_for(owner)).to be_can(capability), "owner should hold #{capability}"
      end
    end

    # @intent: { entity: "RepositoryPolicy", action: "recognise owner", behavior: "the owner reads as both member and owner of their repository", layer: "unit" }
    it "is a member of their own repository" do
      expect(policy_for(owner)).to be_member
      expect(policy_for(owner)).to be_owner
    end
  end

  describe "a member" do
    # @intent: { entity: "RepositoryPolicy", action: "bound member grants", behavior: "a member holds exactly the granted capabilities and none of the ungranted ones", layer: "unit" }
    it "holds exactly the permissions granted, and nothing else" do
      create_membership(repository: repository, user: teammate, permissions: %w[view keys.manage])
      policy = policy_for(teammate)

      expect(policy).to be_can(:view)
      expect(policy).to be_can(:keys_manage)
      expect(policy).not_to be_can(:repo_delete)
      expect(policy).not_to be_can(:members_manage)
    end

    # Managing the keys of a repository you may not open is incoherent, so membership itself is
    # what grants `view` — the string is storable, but it is not what decides.
    # @intent: { entity: "RepositoryPolicy", action: "imply view", behavior: "a member without an explicit view grant can still view the repository", layer: "unit" }
    it "can view the repository even when 'view' was not granted explicitly" do
      create_membership(repository: repository, user: teammate, permissions: %w[keys.manage])

      expect(policy_for(teammate)).to be_can(:view)
    end

    # @intent: { entity: "RepositoryPolicy", action: "imply view from empty grants", behavior: "a membership with no permissions still implies view and nothing more", layer: "unit" }
    it "can view the repository even with no permissions at all" do
      create_membership(repository: repository, user: teammate, permissions: [])

      expect(policy_for(teammate)).to be_can(:view)
      expect(policy_for(teammate)).not_to be_can(:keys_manage)
    end

    # @intent: { entity: "RepositoryPolicy", action: "reserve owner capability", behavior: "a member holding every grantable permission still reads as non-owner", layer: "unit" }
    it "never holds an owner-only capability, however the membership is configured" do
      create_membership(repository: repository, user: teammate,
                        permissions: RepositoryMembership::PERMISSIONS)

      expect(policy_for(teammate)).to be_member
      expect(policy_for(teammate)).not_to be_owner
      expect(policy_for(teammate)).not_to be_can(:owner)
    end
  end

  describe "everyone else" do
    # @intent: { entity: "RepositoryPolicy", action: "deny strangers", behavior: "an unrelated user is not a member and holds no capability including view", layer: "unit" }
    it "is not a member and holds nothing" do
      expect(policy_for(stranger)).not_to be_member
      expect(policy_for(stranger)).not_to be_can(:view)
    end

    # @intent: { entity: "RepositoryPolicy", action: "tolerate nil subjects", behavior: "a nil user or nil repository denies every capability rather than raising", layer: "unit" }
    it "treats a nil user and a nil repository as holding nothing rather than raising" do
      expect(described_class.new(nil, repository)).not_to be_can(:view)
      expect(described_class.new(stranger, nil)).not_to be_can(:view)
      expect(described_class.new(nil, nil)).not_to be_member
    end
  end

  # A typo in a controller must fail on the first request, not quietly deny everyone forever.
  # @intent: { entity: "RepositoryPolicy", action: "reject unknown capability", behavior: "querying an undeclared capability raises ArgumentError naming it", layer: "unit" }
  it "raises on an unknown capability" do
    expect { policy_for(owner).can?(:launch_missiles) }
      .to raise_error(ArgumentError, /launch_missiles/)
  end

  # The bound RepositoryMembership validates a grant against, and the set a future add/edit-member
  # form renders its checkboxes from.
  describe "#grantable_permissions" do
    # @intent: { entity: "RepositoryPolicy#grantable_permissions", action: "grant all to owner", behavior: "the owner may grant every permission in the repository permission set", layer: "unit" }
    it "lets the owner grant every permission there is" do
      expect(policy_for(owner).grantable_permissions).to match_array(RepositoryMembership::PERMISSIONS)
    end

    # @intent: { entity: "RepositoryPolicy#grantable_permissions", action: "bound by held", behavior: "a member may grant only permissions they themselves hold", layer: "unit" }
    it "bounds a member by what they hold themselves" do
      create_membership(repository: repository, user: teammate, permissions: %w[view members.manage])

      expect(policy_for(teammate).grantable_permissions).to match_array(%w[view members.manage])
    end

    # `view` comes from the membership, not from the string, so a row that omits it may still
    # delegate it — otherwise the grant rule and `can?` would disagree about the same person.
    # @intent: { entity: "RepositoryPolicy#grantable_permissions", action: "include implied view", behavior: "a member whose row omits view may still grant it, agreeing with can?", layer: "unit" }
    it "includes 'view' for a member whose row does not store it" do
      create_membership(repository: repository, user: teammate, permissions: %w[keys.manage])

      expect(policy_for(teammate).grantable_permissions).to match_array(%w[view keys.manage])
    end

    # @intent: { entity: "RepositoryPolicy#grantable_permissions", action: "floor at view", behavior: "a permissionless member may grant view and nothing beyond it", layer: "unit" }
    it "gives a member with no permissions nothing beyond 'view'" do
      create_membership(repository: repository, user: teammate, permissions: [])

      expect(policy_for(teammate).grantable_permissions).to eq(%w[view])
    end

    # @intent: { entity: "RepositoryPolicy#grantable_permissions", action: "deny non-members", behavior: "a stranger or nil user or nil repository may grant nothing", layer: "unit" }
    it "lets a non-member — and a nil user or repository — grant nothing" do
      expect(policy_for(stranger).grantable_permissions).to be_empty
      expect(described_class.new(nil, repository).grantable_permissions).to be_empty
      expect(described_class.new(stranger, nil).grantable_permissions).to be_empty
    end

    # A permission added to PERMISSIONS with no matching capability must not silently become
    # ungrantable forever; it fails as loudly as an unknown capability does in `can?`.
    # @intent: { entity: "RepositoryPolicy#grantable_permissions", action: "reject orphan permission", behavior: "a permission with no matching capability raises KeyError rather than being silently ungrantable", layer: "unit" }
    it "raises rather than skipping a permission that maps to no capability" do
      stub_const("RepositoryMembership::PERMISSIONS", RepositoryMembership::PERMISSIONS + %w[repo.transfer])

      expect { policy_for(owner).grantable_permissions }.to raise_error(KeyError)
    end
  end
end
