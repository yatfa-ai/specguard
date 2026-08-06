# frozen_string_literal: true

require "rails_helper"

RSpec.describe RepositoryMembership do
  let(:owner) { create_user }
  let(:repository) { create_repository(user: owner) }
  let(:teammate) { create_user(github_uid: "9999", github_handle: "someone-else") }

  it "grants a user access to a repository they do not own" do
    membership = create_membership(repository: repository, user: teammate, permissions: %w[view keys.manage])

    expect(membership).to be_persisted
    expect(repository.reload.members).to eq([teammate])
    expect(teammate.reload.member_repositories).to eq([repository])
    # Sharing must not change who owns the repository, or which repositories the index lists.
    expect(teammate.repositories).to be_empty
  end

  it "rejects a permission that is not in the known set" do
    membership = described_class.new(repository: repository, user: teammate, permissions: %w[view launch.missiles])

    expect(membership).not_to be_valid
    expect(membership.errors[:permissions].join).to include("launch.missiles")
  end

  it "accepts every permission in the known set" do
    membership = create_membership(repository: repository, user: teammate,
                                   permissions: described_class::PERMISSIONS)

    expect(membership.permissions).to match_array(described_class::PERMISSIONS)
  end

  it "strips and de-duplicates the permission list" do
    membership = create_membership(repository: repository, user: teammate,
                                   permissions: [" view ", "view", "", "keys.manage"])

    expect(membership.permissions).to eq(%w[view keys.manage])
  end

  it "defaults to no permissions rather than NULL" do
    expect(described_class.create!(repository: repository, user: teammate).permissions).to eq([])
  end

  it "refuses a second membership for the same person on the same repository" do
    create_membership(repository: repository, user: teammate)
    duplicate = described_class.new(repository: repository, user: teammate)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:user_id].join).to include("already has a membership")
  end

  # The model validation above races; this is what actually holds the line.
  it "enforces one membership per (user, repository) in the database" do
    create_membership(repository: repository, user: teammate)

    expect {
      described_class.new(repository: repository, user: teammate).save!(validate: false)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # The owner's rights come from Repository#user_id. A row here would be a second, contradictable
  # source of truth for the same fact.
  it "refuses a membership for the repository's own owner" do
    membership = described_class.new(repository: repository, user: owner, permissions: %w[view])

    expect(membership).not_to be_valid
    expect(membership.errors[:user].join).to include("already owns")
  end

  it "is removed when the repository is destroyed" do
    create_membership(repository: repository, user: teammate)

    expect { repository.destroy! }.to change(described_class, :count).by(-1)
  end

  it "is removed when the member is destroyed" do
    create_membership(repository: repository, user: teammate)

    expect { teammate.destroy! }.to change(described_class, :count).by(-1)
  end

  it "is removed when the owner is destroyed, along with the repository" do
    create_membership(repository: repository, user: teammate)

    expect { owner.destroy! }.to change(described_class, :count).by(-1)
    expect(Repository.count).to eq(0)
  end

  # Nobody may grant access they do not hold themselves. Without this, `members.manage` is a lever
  # to every other permission — grant yourself `repo.delete`, then destroy the owner's repository.
  describe "the bound on what a grantor may grant" do
    let(:newcomer) { create_user(github_uid: "5555", github_handle: "newcomer") }
    let(:stranger) { create_user(github_uid: "7777", github_handle: "nobody") }

    # A colleague brought in to onboard the team: they may manage members, and nothing more.
    def onboarder
      teammate.tap do
        create_membership(repository: repository, user: teammate, permissions: %w[view members.manage])
      end
    end

    it "refuses a permission the grantor does not hold, naming it" do
      membership = described_class.new(repository: repository, user: newcomer,
                                       permissions: %w[view repo.delete], granted_by_user: onboarder)

      expect(membership).not_to be_valid
      expect(membership.errors[:permissions].join).to include("repo.delete")
    end

    # The escalation this validation exists to stop: `members.manage` means "edit permissions", and
    # the row a member can edit includes their own.
    it "refuses a member escalating their own row" do
      grantor = onboarder
      own_membership = described_class.find_by!(user: grantor, repository: repository)

      own_membership.granted_by_user = grantor
      own_membership.permissions = %w[view members.manage repo.delete]

      expect(own_membership).not_to be_valid
      expect(own_membership.errors[:permissions].join).to include("repo.delete")
      expect(own_membership.reload.permissions).to match_array(%w[view members.manage])
    end

    it "allows delegation within the grantor's own rights" do
      membership = described_class.create!(repository: repository, user: newcomer,
                                          permissions: %w[view members.manage], granted_by_user: onboarder)

      expect(membership).to be_persisted
      expect(RepositoryPolicy.new(newcomer, repository)).to be_can(:members_manage)
    end

    # Membership implies `view`, so a grantor whose row omits the string still holds the capability.
    it "allows a grantor whose own row omits 'view' to grant 'view'" do
      create_membership(repository: repository, user: teammate, permissions: %w[members.manage])

      membership = described_class.new(repository: repository, user: newcomer,
                                       permissions: %w[view], granted_by_user: teammate)

      expect(membership).to be_valid
    end

    it "lets the owner grant anything, including the permissions that are the point of this rule" do
      membership = described_class.create!(repository: repository, user: newcomer,
                                          permissions: described_class::PERMISSIONS, granted_by_user: owner)

      expect(membership.permissions).to match_array(described_class::PERMISSIONS)
    end

    it "refuses every permission from a grantor who is not a member at all" do
      membership = described_class.new(repository: repository, user: newcomer,
                                       permissions: %w[view], granted_by_user: stranger)

      expect(membership).not_to be_valid
      expect(membership.errors[:permissions].join).to include("view")
    end

    # Fail OPEN: a row saved with no grantor persists exactly as it did before this column existed,
    # which is what keeps the console, the seeds and `create_membership` working unchanged.
    it "persists a row with no grantor, however privileged the grant" do
      membership = create_membership(repository: repository, user: newcomer, permissions: %w[repo.delete])

      expect(membership).to be_persisted
      expect(membership.granted_by_user).to be_nil
    end

    # An unknown value is one mistake and gets one explanation, not "unknown" plus "you don't hold it".
    it "reports an unknown permission once, as unknown" do
      membership = described_class.new(repository: repository, user: newcomer,
                                       permissions: %w[launch.missiles], granted_by_user: onboarder)

      expect(membership).not_to be_valid
      expect(membership.errors[:permissions].size).to eq(1)
      expect(membership.errors[:permissions].join).to include("unknown")
    end

    # Deleting the grantor forgets who granted it; it must never revoke the colleague's access.
    it "keeps the grant when the grantor is deleted, and forgets the grantor" do
      grantor = onboarder
      membership = described_class.create!(repository: repository, user: newcomer,
                                          permissions: %w[view], granted_by_user: grantor)

      grantor.destroy!

      expect(membership.reload.granted_by_user_id).to be_nil
      expect(repository.reload.members).to eq([newcomer])
    end
  end
end
