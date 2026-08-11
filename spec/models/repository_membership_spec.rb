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

  # ...and this is what turns the line holding into a refusal a form can render. When the validation
  # loses the race — its SELECT ran before the competing row was visible — the index raises, and the
  # save path translates that into the SAME `:user_id` error the sequential path produces, so every
  # caller of `save` gets one answer for one condition instead of a 500 for the unlucky half.
  #
  # The race is simulated by silencing the uniqueness validation, which is exactly what it does on
  # its own when it cannot see the other row yet. Attribute matters: `:user_id`, not `:base` — the
  # sequential example above reads it off `:user_id`, and the controller renders `full_message`, so
  # landing it anywhere else changes the sentence the owner is shown.
  it "translates a lost uniqueness race into the same :user_id refusal" do
    create_membership(repository: repository, user: teammate)
    duplicate = described_class.new(repository: repository, user: teammate)
    allow(uniqueness_validator(described_class)).to receive(:validate_each)

    expect(duplicate.save).to be(false)
    expect(duplicate.errors[:user_id].join).to include("already has a membership")
    expect(duplicate).not_to be_persisted
    expect(described_class.count).to eq(1)
  end

  # The refusal above has to leave the CONNECTION usable, not just report itself politely.
  #
  # Postgres aborts the whole transaction on a constraint violation, so a rescue with no savepoint
  # returns a clean `false` with a readable sentence on it while every subsequent statement on that
  # connection dies with `PG::InFailedSqlTransaction`. That is strictly worse than the 500 this
  # translation exists to remove: the caller is told the save was refused, and finds out the rest
  # later, somewhere else.
  #
  # The explicit `transaction` here is what makes the example load-bearing, and it is NOT redundant
  # with the suite's transactional fixtures — those open non-joinable, which forces a savepoint
  # whether the model asks for one or not, so every other example in this file would stay green
  # against a model that opened none. This one opens a JOINABLE transaction, the kind application
  # code writes, which is the only shape that can be poisoned. The query after the failed save is
  # the assertion: it either answers, or the connection is already dead.
  it "leaves an enclosing transaction usable after refusing the race" do
    create_membership(repository: repository, user: teammate)
    duplicate = described_class.new(repository: repository, user: teammate)
    allow(uniqueness_validator(described_class)).to receive(:validate_each)

    ActiveRecord::Base.transaction do
      expect(duplicate.save).to be(false)
      expect(described_class.count).to eq(1)
    end
  end

  # A conflict on some OTHER constraint is not this one's to explain away. Swallowing every
  # `RecordNotUnique` would turn an unrelated index violation into "already has a membership" — a
  # wrong sentence is worse than the raise, because it sends the owner to fix something that is
  # fine, and it reports `save` as a clean refusal when the real fault is still there. Provoked
  # with a genuine second violation on this same table — a primary-key collision, for a row that is
  # *not* a duplicate membership.
  it "re-raises a unique violation that is not the duplicate-membership index" do
    existing = create_membership(repository: repository, user: teammate)
    third_party = create_user(github_uid: "5150", github_handle: "third-party")
    clashing = described_class.new(id: existing.id, repository: repository, user: third_party)

    expect { clashing.save }.to raise_error(ActiveRecord::RecordNotUnique)
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

  # The two examples that follow used to assert the opposite — that destroying a user took their
  # memberships (and, for an owner, the whole repository) with them. That cascade is exactly what
  # `User`'s `dependent: :restrict_with_error` removed: a membership is a person's access to
  # somebody else's repository, and deleting the person must never be the way it disappears.
  it "is not removed when the member is destroyed — the member is refused instead" do
    create_membership(repository: repository, user: teammate)

    expect { expect(teammate.destroy).to be(false) }.not_to change(described_class, :count)
    expect(teammate.errors[:base]).to be_present
    expect(teammate.reload).to be_persisted
  end

  it "is not removed when the owner is destroyed — the owner is refused, and the repository stays" do
    create_membership(repository: repository, user: teammate)

    expect { expect(owner.destroy).to be(false) }.not_to change(described_class, :count)
    expect(owner.errors[:base]).to be_present
    expect(Repository.count).to eq(1)
    expect(repository.reload).to be_persisted
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
    #
    # The grantor has to be stripped back to owning nothing and holding nothing before they are
    # deletable at all — `User` declares `dependent: :restrict_with_error` on `repositories` and
    # `repository_memberships`. That is not a workaround to keep this example green, it is the only
    # shape the scenario can have: `grantor_holds_every_granted_permission` forbids granting a
    # permission you do not hold, so every valid grantor either owns the repository or holds a
    # membership on it. "The grantor left" therefore *means* their own access went first, and this
    # models exactly that sequence. The assertion below is unchanged, and is about
    # `granted_by_user`'s `:nullify`, which this ticket deliberately preserves.
    it "keeps the grant when the grantor is deleted, and forgets the grantor" do
      grantor = onboarder
      membership = described_class.create!(repository: repository, user: newcomer,
                                          permissions: %w[view], granted_by_user: grantor)

      described_class.find_by!(user: grantor, repository: repository).destroy!
      grantor.destroy!

      expect(membership.reload.granted_by_user_id).to be_nil
      expect(repository.reload.members).to eq([newcomer])
    end
  end
end
