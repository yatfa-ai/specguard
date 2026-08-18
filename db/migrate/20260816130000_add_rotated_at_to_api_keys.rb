# frozen_string_literal: true

# WHEN THIS KEY'S CURRENT TOKEN WAS MINTED IN PLACE OF AN EARLIER ONE — the fact `regenerate!`
# performed but never recorded.
#
# `ApiKey#regenerate!` overwrites `token_digest` and nothing else, so the retired token stops
# authenticating with no grace window while every other column keeps describing the key as it was.
# `last_used_at` is the one that matters: it is deliberately preserved across a rotation (SPGD-352
# settled that — it is the key's history, and nulling it would flip the repository Connection stat
# to "not connected"), which means the row carries a fresh digest beside a use stamped by the token
# that digest replaced. Until the replacement reaches CI every delivery 401s, and for that whole
# window the Connection stat, the key list and the agent API all read healthy — each describing a
# token that no longer exists.
#
# The surface had only two states to choose between, so the fix was either to destroy history or to
# keep lying. This column is the third: it does not touch `last_used_at`, it dates the event that
# makes `last_used_at` misattributed, and `ApiKey#rotated_and_unused?` reads the two together.
#
# NULLABLE, and `NULL` is load-bearing: it means *never rotated*, which is every key that exists
# today and every key minted from now until someone regenerates it. It is not "unknown" and it is
# not backfilled — a rotation that happened before this column existed left no trace anywhere to
# recover it from (the previous digest is overwritten, not kept), and inventing a timestamp for it
# would mark keys as rotated-and-unused that nobody has touched. A `NULL` here reads exactly as the
# product read before this migration.
#
# NO INDEX. The column is read per-row on rows already loaded — the key list has them, and the
# Connection stat derives its verdict from the same loaded collection — and it is never a WHERE or
# an ORDER BY. An index here would be write cost bought for no reader.
class AddRotatedAtToApiKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :api_keys, :rotated_at, :datetime
  end
end
