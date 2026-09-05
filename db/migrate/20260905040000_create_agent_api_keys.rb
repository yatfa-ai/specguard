# frozen_string_literal: true

# THE THIRD CREDENTIAL — an agent key (`sga_`) that carries an explicit SET of repositories and a
# permission set, both fixed at mint time. The sibling tables state the two credentials this one
# stands between:
#
# * `api_keys` (`sgk_`) speaks for ONE repository and resolves `current_repository` — the
#   ingest credential. Its `repository_id` is `NOT NULL` and the ingest path leans on that
#   structurally; see `create_user_api_keys` for why that table was never relaxed to hold
#   person-shaped rows.
# * `user_api_keys` (`sgu_`) speaks for ONE PERSON across everything that person may open.
#
# Neither answers "an agent reads N repositories without holding a person's rights". `sgk_` is one
# repository by design, and `sgu_` speaks with the person's full grantable surface — over-privilege
# for an automated agent. This table is the bounded form: the repository set IS the read boundary,
# and the permission set (the `repository_memberships.permissions` text[] vocabulary, verbatim)
# gates every verb past reading.
#
# ## Why two array columns and not a join table
#
# The grants are one mint-time fact about the key — a set of repositories, a set of permissions —
# that never changes after minting and is read whole on every authorization. There is no per-grant
# lifecycle to model (no per-repository revoke, no grantor attribution per row), which is the work
# a join table exists for. `text[]` is also the precedent the permission column follows:
# `repository_memberships.permissions` is the same vocabulary stored the same way, so "what a
# membership holds" and "what an agent key holds" read identically in Ruby.
#
# A repository later deleted leaves its id dangling here harmlessly: resolution goes through
# `Repository.where(id: repository_ids)`, and a missing row is a 404 — the same nil-is-404 fork
# every scoped read on this application takes. No foreign key can express that array anyway.
#
# ## `revoked_at` — the retirement pattern, not a deletion
#
# Same shape `api_keys` carries it in (`add_retirement_columns_to_api_keys`): the stamp is written
# by `AgentApiKey#revoke!`, never cleared, and the ROW STAYS — so a still-presenting revoked token
# stays attributable to a row this application owns rather than resolving to nothing and reading
# "no such key". Unlike `api_keys` there is no `last_refused_at` yet: no surface reports a
# still-presented revoked agent key, and an unused column would be write cost bought for no reader.
class CreateAgentApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_api_keys do |t|
      # The person who minted the key — its OWNER. `null: false` for the reason
      # `user_api_keys.user_id` is: a credential minted by nobody is a credential whose rights
      # have no source, and the grant validations below read this column as the grantor.
      t.references :user, null: false, foreign_key: true
      # `null: false` like `user_api_keys.name`: an owner may hold several agent keys (one per
      # agent, one per fleet), and the name is what tells them apart on the revoke button.
      t.string :name, null: false
      t.string :token_digest, null: false

      # THE READ BOUNDARY — the repositories this key may name, fixed at mint time.
      t.bigint :repository_ids, null: false, default: [], array: true
      # THE VERB BOUNDARY — `RepositoryMembership::PERMISSIONS` strings, holding for every
      # repository in the set above.
      t.text :permissions, null: false, default: [], array: true

      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    # Unique, and it is the whole resolution path — `AgentApiKey.authenticate` looks a digest up
    # here and compares nothing else, exactly as both sibling credentials resolve.
    add_index :agent_api_keys, :token_digest, unique: true
  end
end
