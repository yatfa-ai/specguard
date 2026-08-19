# frozen_string_literal: true

# A credential that speaks for a PERSON rather than for one repository — the other half of the
# `api_keys` table, deliberately kept as a second table rather than folded into it.
#
# ## Why not a nullable `repository_id` on `api_keys`
#
# `api_keys.repository_id` is `NOT NULL`, and the ingest path structurally leans on that: every
# machine endpoint shipped today reaches `Ingest::RunRecorder.record(current_repository, …)` on the
# strength of "authentication resolved a repository, so there is one". Relaxing that column to
# accommodate rows which are not repository keys at all would convert a class of bug the database
# currently refuses — telemetry attributed to no repository — into one only Ruby refuses. A separate
# table leaves every `ApiKey` guarantee byte-identical, and this one carries its own `NOT NULL`
# binding to the thing it actually names.
#
# ## Why the digest index is unique here too
#
# Resolution is digest-only and O(1) on that index, exactly as `ApiKey.authenticate` is. The two
# tables are told apart BEFORE either is read, by the token's prefix (`sgu_` here, `sgk_` there) —
# see `Api::BaseController#authenticate_api_key!` — so having two credential tables costs no second
# query, and a token presented to the wrong surface fails on the first read.
class CreateUserApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :user_api_keys do |t|
      # `null: false`, unlike `api_keys.created_by_user_id` which is nullable attribution. That
      # column records who MINTED a key belonging to a repository; this column IS the key's meaning.
      # A row here with no user would be a credential authenticating as nobody.
      t.references :user, null: false, foreign_key: true
      # `null: false` and no default, unlike `api_keys.name`. A person is expected to hold several
      # of these at once — one per laptop, one per agent — so the name is the only thing telling two
      # rows apart on the revoke button, and a shared default would make that impossible.
      t.string :name, null: false
      t.string :token_digest, null: false

      t.datetime :last_used_at

      t.timestamps
    end

    # Unique, and it is the whole resolution path: `UserApiKey.authenticate` looks a digest up here
    # and compares nothing else.
    add_index :user_api_keys, :token_digest, unique: true
  end
end
