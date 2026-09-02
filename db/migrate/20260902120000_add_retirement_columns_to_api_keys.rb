# frozen_string_literal: true

# RETIREMENT, NOT DELETION — the fact `ApiKeysController#destroy` performed but never recorded.
#
# Revoking a key was a hard `destroy!`: the row went away, and with it every fact the row carried.
# A CI pipeline that kept presenting the revoked token then 401'd forever on a repository whose page
# read "Not connected yet" / "No API key has been used." in neutral tone — because `ApiKey.authenticate`
# resolving nothing leaves nothing to attribute a record to, and the page can only report what a row
# carries. The unattributability was not a property of the 401; it was this line discarding the only
# artifact that could have made the failure visible (the same move that made rotation reportable:
# keep the row, stamp the instant, derive the state — see `add_rotated_at_to_api_keys`).
#
# TWO columns, because the state has two halves:
#
# * `revoked_at` — the instant the token was retired. Written by `ApiKey#revoke!` (the `destroy!`
#   this migration retires). NULL means *never revoked* — every key that exists today, and the
#   reading every pre-migration row gets. It is not "unknown" and it is not backfilled: a revocation
#   that happened before this column existed deleted its row outright, and there is nothing to
#   recover it from.
#
# * `last_refused_at` — the last time a client presented this row's (dead) token and was refused.
#   Written by `Api::BaseController`'s failure path, the one place a 401 becomes attributable: the
#   request resolved no principal, but the digest names exactly one row, and this platform owns it.
#   NULL means the token has not been seen since revocation — including the honest majority case of
#   "revoked and never presented again", which must not be synthesized into a finding.
#
# NO INDEX on either. `revoked_at` is read per-row on rows already loaded (the keys SELECT on
# `repositories#show` carries them all, and every consumer partitions in Ruby) and filters nothing
# at the database; `last_refused_at` is the same. The failure path's lookup runs on the unique
# `token_digest` index that already serves resolution, with `revoked_at` checked on the row it
# returns. An index here would be write cost bought for no reader.
class AddRetirementColumnsToApiKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :api_keys, :revoked_at, :datetime
    add_column :api_keys, :last_refused_at, :datetime
  end
end
