# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260806120000_add_created_by_user_to_api_keys")

# Attribution is not recoverable after the fact — `ApiKeysController#destroy` is a hard `destroy!`
# with no audit row — so the backfill is the only chance a pre-existing key ever gets a creator.
# These examples call the migration's own backfill method, not a re-typed copy of its SQL.
RSpec.describe AddCreatedByUserToApiKeys do
  # One instance, not two: `suppress_messages` toggles `@verbose` on its *receiver* and restores it
  # in an ensure, so suppressing on one instance while running the backfill on another suppresses
  # nothing.
  def backfill!
    migration = described_class.new
    migration.suppress_messages { migration.backfill_creators_from_repository_owners }
  end

  # Simulates a key minted before the column existed: attributable only through its repository.
  # `create!` with no creator already leaves `created_by_user_id` NULL — there is no default to undo.
  def unattributed_key(repository, name: "Legacy CI")
    repository.api_keys.create!(name: name)
  end

  # @intent: { entity: "AddCreatedByUserToApiKeys", action: "backfill creators from repository owners", behavior: "a key minted before the column existed ends up attributed to the user who owns its repository", layer: "integration" }
  it "attributes a pre-existing key to its repository's owner" do
    repository = create_repository
    api_key = unattributed_key(repository)

    backfill!

    expect(api_key.reload.created_by_user).to eq(repository.user)
  end

  # @intent: { entity: "AddCreatedByUserToApiKeys", action: "backfill creators from repository owners", behavior: "every legacy key across multiple owners gets attributed, each to its own repository owner rather than an arbitrary one", layer: "integration" }
  it "leaves no key unattributed" do
    owner = create_user
    other_owner = create_user(github_uid: "2002", github_handle: "hubot")
    mine = create_repository(user: owner)
    theirs = create_repository(user: other_owner, github_full_name: "hubot/deploys")
    unattributed_key(mine)
    unattributed_key(mine, name: "Staging")
    unattributed_key(theirs)

    backfill!

    expect(ApiKey.where(created_by_user_id: nil)).to be_empty
    # Each key follows *its own* repository's owner — not whichever user happened to be first.
    expect(mine.api_keys.pluck(:created_by_user_id).uniq).to eq([owner.id])
    expect(theirs.api_keys.pluck(:created_by_user_id).uniq).to eq([other_owner.id])
  end

  # @intent: { entity: "AddCreatedByUserToApiKeys", action: "backfill creators from repository owners", behavior: "rows that already carry a creator keep the recorded minter even though the repository owner differs", layer: "integration" }
  it "does not overwrite a creator that is already recorded" do
    minter = create_user(github_uid: "3003", github_handle: "collaborator")
    repository = create_repository
    api_key = repository.api_keys.create!(name: "CI", created_by_user: minter)

    backfill!

    expect(api_key.reload.created_by_user).to eq(minter)
    expect(api_key.created_by_user).not_to eq(repository.user)
  end
end
