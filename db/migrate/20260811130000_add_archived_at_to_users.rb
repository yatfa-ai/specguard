# frozen_string_literal: true

# The first lifecycle state `users` has ever had. Archiving means exactly two things today: the
# person cannot sign in, and cannot be invited to a repository. NOTHING is destroyed or nullified
# by it — every repository, test run, spec intent, API key and membership they are attached to
# stays exactly as it was, attribution intact. That is the whole point: the alternative to an
# archive is a delete, and `User#destroy` still cascades into repositories and all their telemetry
# (see `user.rb` and `repository.rb`).
#
# A `*_at` timestamp rather than a boolean, matching every other state this schema records: it
# answers "when", which is what an audit trail of an offboarding actually wants, and "is it set"
# answers the boolean question for free.
#
# Nullable and additive, with no backfill: every existing row is active, which is what NULL already
# means here. Deliberately NOT wired to a `default_scope` — see the note on `User.active`.
class AddArchivedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :archived_at, :datetime
  end
end
