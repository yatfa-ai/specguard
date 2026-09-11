# frozen_string_literal: true

# RETIREMENT, NOT DELETION — for the PERSONAL `sgu_` credential, the fact
# `UserApiKeysController#destroy` performed but never recorded. The repository-key half of this
# shipped as `add_retirement_columns_to_api_keys` (SPGD-804); SPGD-943 ports the same shape here,
# where it is the *more* urgent half: an `sgu_` key is handed to an agent or an MCP client, there
# is no `regenerate!` (deliberately — mint-and-revoke is the entire lifecycle), and revocation was
# the one lever that kept no record. A hard `destroy!` left one row and no trail, while two
# committed comments on the very files involved promised "two rows and an audit trail".
#
# TWO columns, because the state has two halves — same rationale as the `api_keys` migration:
#
# * `revoked_at` — the instant the token was retired. Written by `UserApiKey#revoke!` (the
#   `destroy!` this migration retires). NULL means *never revoked* — every key that exists today,
#   and the reading every pre-migration row gets. It is not "unknown" and it is not backfilled:
#   a revocation that happened before this column existed deleted its row outright, and there is
#   nothing to recover it from.
#
# * `last_refused_at` — the last time a client presented this row's (dead) token and was refused.
#   Written by `Api::BaseController`'s failure path, which since SPGD-804 has stamped the
#   repository credential and been class-guarded away from this one; the widening is deliberate
#   (`base_controller.rb` says so where the guard used to). NULL means the token has not been seen
#   since revocation — including the honest majority case of "revoked and never presented again",
#   which must not be synthesized into a finding.
#
# NO INDEX on either. `revoked_at` is read per-row on rows already loaded (the account page's key
# SELECT carries them all, and the page partitions in Ruby) and filters nothing at the database;
# `last_refused_at` is the same. The failure path's lookup runs on the unique `token_digest` index
# that already serves resolution, with `revoked_at` checked on the row it returns. An index here
# would be write cost bought for no reader.
class AddRetirementColumnsToUserApiKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :user_api_keys, :revoked_at, :datetime
    add_column :user_api_keys, :last_refused_at, :datetime
  end
end
