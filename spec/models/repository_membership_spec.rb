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
end
