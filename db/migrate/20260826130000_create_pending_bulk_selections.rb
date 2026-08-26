# frozen_string_literal: true

# THE BATCH SOMEBODY TICKED, HELD SERVER-SIDE WHILE THEY TAKE A TRIP TO GITHUB AND COME BACK.
#
# The summary's fix buttons send the reader to github.com and back, and they carry the reader's
# selection so that pressing the button which RESOLVES the refusal costs no more than pressing the
# one beside it that merely re-submits. Everything carried rides out through GitHub's `state`
# parameter — part of a URL on somebody else's site — so the carry has a byte budget that is not
# ours to set and not one we can raise (`GithubHelper::MAX_RETURN_TO_BYTES` states its derivation).
#
# Carrying the NAMES in that URL fit 28 of the 100 batch sizes the product accepts, and above 28 the
# whole list was dropped: a person who ticked thirty repositories, was refused, pressed the button
# that fixes it, and came back, landed on an unticked list and re-picked thirty by hand — precisely
# the cost the button exists to remove. This table is the remedy, and the remedy is to stop putting
# the list in the URL at all: the row holds the names, the URL holds a ~22-byte handle to the row,
# and `organization` + handle fits at every size in `1..BulkRegistration::MAX_BATCH`.
#
# ## Why a table, and not the two cheaper-looking places
#
# NOT the session. This app has no `config/initializers/session_store.rb`, so it is on Rails'
# default COOKIE store with its 4KB ceiling. A hundred names is ~2.6KB raw before encryption and
# encoding inflation, and the session already carries the GitHub user token and its expiry
# (`GithubUserSession::TOKEN_KEY` / `EXPIRES_KEY`) — the credential `github_authorization_needed?`
# turns on. A batch-sized stash risks `CookieOverflow`, and a NEAR miss is worse than an overflow:
# it quietly evicts the token instead, breaking verification with nothing raised.
#
# NOT `Rails.cache`. `config/environments/test.rb` sets `cache_store = :null_store` and production's
# `cache_store` line is commented out — so a cache-backed handle would silently no-op under test
# (every acceptance test passing or failing for reasons unrelated to the code) and would have no
# configured backing in production either.
#
# ## One row per TRIP, not one row per user
#
# `github_registration_grants` — the nearest neighbour in shape, and the model this follows in
# documentation style — is deliberately one row per user, replaced wholesale, because a grant is a
# statement about a person that is only ever true in its latest version. A pending selection is the
# opposite: it is a statement about ONE trip, and a person can have two summaries open in two tabs.
# One row per user would mean the second tab's render silently overwrites the first tab's selection,
# and the first tab's button would then come back ticking a batch its reader never chose — a wrong
# answer that looks exactly like a right one. So the handle names a row rather than a person, and
# the `user_id` on it is the scope every read is made through, never the key.
#
# ## The handle is opaque, and the scope is what makes it safe
#
# `token` is random rather than the row id: a sequential id in a URL invites a reader to try id-1.
# That try already resolves to nothing — redemption is `find_by(user_id:, token:)`, so another
# person's handle is not found at all rather than found and refused — but an unguessable handle
# means the attempt is not worth making. The token is the whole of what the URL carries.
#
# ## `captured_at` is not `updated_at`
#
# It is the age the expiry bound is measured against, and it moves only when a selection was
# actually taken. `updated_at` moves on any write to the row. See `PendingBulkSelection::MAX_AGE`
# for why the bound is an hour rather than the grant table's week: this is a round trip through one
# website, not a credential standing in for a session.
class CreatePendingBulkSelections < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_bulk_selections do |t|
      # NOT unique — see the header. The scope of every read, never the key of one.
      t.references :user, null: false, foreign_key: true

      # The handle, and the only part of this row that appears in a URL.
      t.string :token, null: false, index: { unique: true }

      # The account the batch was picked from. Carried so a row can be read and understood on its
      # own; it gates nothing, because the listing the picker renders is already the gate — a
      # resolved name that is not in it simply matches no row.
      t.string :organization, null: false

      t.jsonb :full_names, null: false, default: []

      # No default: a row that exists without a stamp would be a selection of unknown age, and the
      # expiry bound could not be applied to it.
      t.datetime :captured_at, null: false

      t.timestamps
    end

    # The sweep's access path: expired rows for one person, deleted when that person takes their
    # next trip. See `PendingBulkSelection.capture`.
    add_index :pending_bulk_selections, %i[user_id captured_at]
  end
end
