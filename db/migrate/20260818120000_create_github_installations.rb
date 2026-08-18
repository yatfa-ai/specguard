# frozen_string_literal: true

# Which GitHub App installations a user reached SpecGuard through.
#
# An installation is the whole of the ownership proof: only somebody who administers a repository
# can install a GitHub App on it, so a repository's presence in a user's installation is GitHub's
# own statement that this user may register it. That replaces the `permissions.admin` read the
# OAuth `repo` scope existed to make.
#
# ## What is stored, and what deliberately is not
#
# Only `installation_id` — a public numeric identifier, not a secret. The credential SpecGuard
# actually reads GitHub with is an installation access token minted on demand from the App's
# private key and discarded within the hour (`GithubAppCredentials`), so there is no token column
# here and no encryption to configure. `account_login` rides along purely so the UI can name the
# account a user connected without a GitHub round trip.
#
# ## Why the id is not unique on its own
#
# One installation can legitimately be reached by several users: two admins of the same
# organization each install (or re-visit) the App and each get a row pointing at the same
# installation. The uniqueness that matters is per user, so a second visit updates one row rather
# than growing a new one on every trip through the setup URL.
#
# `installation_id` is a bigint because GitHub's ids are already past the 32-bit range.
class CreateGithubInstallations < ActiveRecord::Migration[8.1]
  def change
    create_table :github_installations do |t|
      t.references :user, null: false, foreign_key: true
      t.bigint :installation_id, null: false
      t.string :account_login

      t.timestamps
    end

    add_index :github_installations, %i[user_id installation_id], unique: true
    add_index :github_installations, :installation_id
  end
end
