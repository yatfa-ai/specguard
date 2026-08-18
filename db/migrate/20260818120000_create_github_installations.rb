# frozen_string_literal: true

# Which GitHub App installations a user reached SpecGuard through.
#
# A row here is HALF the ownership proof, and the half that is about the repository rather than
# about the person. Only somebody who administers a repository can install a GitHub App on it, so a
# repository's presence in an installation is GitHub's statement that SOMEBODY with administrative
# rights handed it to SpecGuard. It is not a statement about whoever is reading the row: GitHub
# shows an organization's installation to every member of that organization. The other half — does
# THIS user administer THIS repository — is read live, per user, with that user's own credential
# (`InstallationRepositories`), and both halves must hold before anything is registered.
#
# ## What is stored, and what deliberately is not
#
# Only `installation_id` — a public numeric identifier, not a secret, and not usable as one. The
# credential SpecGuard reads GitHub with is the viewer's own short-lived user-to-server token,
# which lives in their session and never in this database. So there is no token column here and no
# encryption to configure. `account_login` rides along purely so the UI can name the account a user
# connected without a GitHub round trip.
#
# ## Why the id is not unique on its own
#
# One installation is legitimately reached by many users: every member of an organization can see
# that organization's installation, and each gets a row pointing at the same id. The uniqueness that
# matters is per user, so a second visit updates one row rather than growing a new one on every trip
# through the callback. Two users holding the same id is the NORMAL case, not a collision — and it
# is exactly why the row cannot be read as permission.
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
