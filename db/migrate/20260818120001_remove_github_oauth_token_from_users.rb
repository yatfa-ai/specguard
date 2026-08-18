# frozen_string_literal: true

# Removes the OAuth repository path's storage. The columns went in with SPGD-354 to hold a token
# granted under GitHub's `repo` scope — "Full control of private repositories", read and write, on
# every repository the user and their organizations could reach — in order to read one boolean off
# `GET /repos/:owner/:repo`. Repository access is now a GitHub App installation, whose credential is
# the viewer's own short-lived user-to-server token, held in their session and never in a column,
# so nothing writes or reads these.
#
# ## No migration path, deliberately
#
# There are zero registered repositories in production, so there is nothing to preserve, re-verify
# or migrate. The rows these columns held are credentials rather than data: dropping them is the
# point of the change, not a cost of it. A user reconnects by installing the App, which is one
# click and asks for far less than the token being dropped here did.
#
# `up`/`down` rather than `change` so the rollback is honest. Rolling back restores three empty
# columns and NOT the tokens that were in them — no rollback could, since the plaintext was never
# ours to reconstruct — and a `change` block would otherwise present that as a reversible edit.
class RemoveGithubOauthTokenFromUsers < ActiveRecord::Migration[8.1]
  def up
    change_table :users, bulk: true do |t|
      t.remove :github_access_token
      t.remove :github_token_scopes
      t.remove :github_token_updated_at
    end
  end

  def down
    change_table :users, bulk: true do |t|
      t.text :github_access_token
      t.string :github_token_scopes
      t.datetime :github_token_updated_at
    end
  end
end
