# frozen_string_literal: true

# Records who granted each membership, so a grant can be bounded by what its grantor holds.
#
# Nullable, and there is deliberately **no backfill**. The api_keys equivalent could infer a creator
# ("only owners could mint, so the creator is the repository owner"); nothing equivalent is true
# here. Memberships have never had a write path — `MembershipsController` is `index` + `destroy`
# only — so every existing row was written by a spec builder or the console, by nobody the schema
# can name. Inventing the owner as grantor would be a fabricated audit trail, which is worse than an
# honest NULL. Rows with no grantor keep persisting exactly as before (see
# `RepositoryMembership#grantor_holds_every_granted_permission`).
#
# The foreign key follows `20260806120000_add_created_by_user_to_api_keys`, and so does the reason
# it is nullable rather than NOT NULL: attribution belongs to the grant, not the other way round, so
# deleting the grantor must degrade the row to "unknown grantor" rather than revoke a colleague's
# access (`User has_many :granted_repository_memberships, dependent: :nullify`). A NOT NULL column
# would make that nullify impossible.
class AddGrantedByUserToRepositoryMemberships < ActiveRecord::Migration[8.1]
  def change
    add_reference :repository_memberships, :granted_by_user, null: true, index: true,
                                                             foreign_key: { to_table: :users }
  end
end
