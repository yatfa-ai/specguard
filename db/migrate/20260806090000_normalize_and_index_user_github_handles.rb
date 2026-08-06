# frozen_string_literal: true

# `users.github_handle` is being promoted from a display string to a lookup key
# (`User.resolve_by_handle`). Canonicalise what is already stored, then index it — the lookup is a
# full table scan today.
#
# The index is deliberately NOT unique. Two rows may legitimately hold the same handle: a row keeps
# whatever handle its owner had at their last sign-in, so a recycled GitHub handle can appear twice.
# A unique index would make `save!` inside the sign-in path raise for the innocent second user.
# Ambiguity is reported at read time by `User.resolve_by_handle` instead.
class NormalizeAndIndexUserGithubHandles < ActiveRecord::Migration[8.1]
  def up
    # Not reversible: the original casing/whitespace is not recoverable, and does not need to be.
    execute <<~SQL.squish
      UPDATE users
         SET github_handle = lower(btrim(github_handle)), updated_at = now()
       WHERE github_handle <> lower(btrim(github_handle))
    SQL

    add_index :users, :github_handle
  end

  def down
    remove_index :users, :github_handle
  end
end
