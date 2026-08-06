# frozen_string_literal: true

# Records who minted each API key.
#
# Attribution is not backfillable after the fact: `ApiKeysController#destroy` is a hard `destroy!`
# with no audit row, so a key minted before this column exists can never be attributed later. The
# backfill below is only unambiguous *today*, while `#create` is reachable by the repository owner
# alone — every existing key's creator therefore is `repositories.user_id`. Once a members UI ships,
# that inference is gone.
#
# The column is deliberately nullable: an API key belongs to the *repository*, not to the person who
# happened to mint it, so deleting that person must nullify the attribution rather than delete the
# owner's live CI credential (`User has_many :created_api_keys, dependent: :nullify`). A NOT NULL
# column would make that nullify impossible.
class AddCreatedByUserToApiKeys < ActiveRecord::Migration[8.1]
  def up
    add_reference :api_keys, :created_by_user, null: true, index: true,
                                               foreign_key: { to_table: :users }

    backfill_creators_from_repository_owners
  end

  def down
    remove_reference :api_keys, :created_by_user, foreign_key: { to_table: :users }
  end

  # Public so `spec/migrations/add_created_by_user_to_api_keys_spec.rb` can exercise the *real*
  # backfill rather than a copy of its SQL — a copied query proves nothing about this migration.
  #
  # Unambiguous only while owners alone can mint: creator == repository owner.
  def backfill_creators_from_repository_owners
    execute <<~SQL.squish
      UPDATE api_keys
         SET created_by_user_id = repositories.user_id
        FROM repositories
       WHERE repositories.id = api_keys.repository_id
         AND api_keys.created_by_user_id IS NULL
    SQL
  end
end
