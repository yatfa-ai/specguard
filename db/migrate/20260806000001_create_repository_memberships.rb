# frozen_string_literal: true

# Repository sharing, slice 1: a second person can be granted access to someone else's repository.
#
# Purely additive — no existing table is touched. `github_full_name` stays globally unique, which
# is precisely why sharing has to exist: a teammate cannot register `org/repo` themselves (the
# uniqueness validation rejects it with 422), so a membership row is the only path in.
#
# `permissions` is a Postgres `text[]` rather than a join table of role rows: the permission set is
# four fixed strings, and a role entity would be machinery this slice does not need. The unique
# index on (user_id, repository_id) is the identity of a membership — one row per person per repo,
# enforced by the database and not only by the model.
class CreateRepositoryMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :repository_memberships do |t|
      # No standalone index on user_id: the unique (user_id, repository_id) index below leads with
      # it, so it already serves every "what is this user a member of?" lookup.
      t.references :user,       null: false, foreign_key: true, index: false
      t.references :repository, null: false, foreign_key: true
      t.text :permissions, array: true, null: false, default: []
      t.timestamps
    end

    add_index :repository_memberships, [:user_id, :repository_id], unique: true,
      name: "index_repository_memberships_on_user_and_repository"
  end
end
