# frozen_string_literal: true

require "rails_helper"

RSpec.describe RepositoryPolicy do
  let(:owner) { create_user }
  let(:repository) { create_repository(user: owner) }
  let(:teammate) { create_user(github_uid: "9999", github_handle: "someone-else") }
  let(:stranger) { create_user(github_uid: "7777", github_handle: "nobody") }

  def policy_for(user) = described_class.new(user, repository)

  describe "the owner" do
    it "holds every capability without a membership row" do
      expect(RepositoryMembership.count).to eq(0)

      described_class::CAPABILITIES.each_key do |capability|
        expect(policy_for(owner)).to be_can(capability), "owner should hold #{capability}"
      end
    end

    it "is a member of their own repository" do
      expect(policy_for(owner)).to be_member
      expect(policy_for(owner)).to be_owner
    end
  end

  describe "a member" do
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
    it "can view the repository even when 'view' was not granted explicitly" do
      create_membership(repository: repository, user: teammate, permissions: %w[keys.manage])

      expect(policy_for(teammate)).to be_can(:view)
    end

    it "can view the repository even with no permissions at all" do
      create_membership(repository: repository, user: teammate, permissions: [])

      expect(policy_for(teammate)).to be_can(:view)
      expect(policy_for(teammate)).not_to be_can(:keys_manage)
    end

    it "never holds an owner-only capability, however the membership is configured" do
      create_membership(repository: repository, user: teammate,
                        permissions: RepositoryMembership::PERMISSIONS)

      expect(policy_for(teammate)).to be_member
      expect(policy_for(teammate)).not_to be_owner
      expect(policy_for(teammate)).not_to be_can(:owner)
    end
  end

  describe "everyone else" do
    it "is not a member and holds nothing" do
      expect(policy_for(stranger)).not_to be_member
      expect(policy_for(stranger)).not_to be_can(:view)
    end

    it "treats a nil user and a nil repository as holding nothing rather than raising" do
      expect(described_class.new(nil, repository)).not_to be_can(:view)
      expect(described_class.new(stranger, nil)).not_to be_can(:view)
      expect(described_class.new(nil, nil)).not_to be_member
    end
  end

  # A typo in a controller must fail on the first request, not quietly deny everyone forever.
  it "raises on an unknown capability" do
    expect { policy_for(owner).can?(:launch_missiles) }
      .to raise_error(ArgumentError, /launch_missiles/)
  end
end
