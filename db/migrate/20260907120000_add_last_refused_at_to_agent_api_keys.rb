# frozen_string_literal: true

# THE REFUSAL STAMP, third credential — the column `create_agent_api_keys` declared a deferral,
# discharged now that the reader is live: `/account` shows revoked agent-key rows, and a row
# carrying no refusal datum cannot answer the only question an owner of a LEAKED token is asking
# ("is it still knocking?"). This is `add_retirement_columns_to_api_keys`'s `last_refused_at`,
# ported unchanged in meaning: written by `Api::BaseController`'s failure path — the one place a
# 401 becomes attributable — and read by `AgentApiKey#revoked_and_still_presented?` to date the
# last observed presentation.
#
# NULL means the token has not been seen since revocation — including the honest majority case of
# "revoked and never presented again", which must not be synthesized into a finding. NO BACKFILL
# for that reason and the same one its `api_keys` sibling states: a refusal that happened before
# this column existed was never recorded anywhere, and there is nothing to recover it from.
#
# NO INDEX, for the same reason its sibling has none: `last_refused_at` is read per-row on rows
# already loaded (the /account SELECT carries every one of the owner's keys) and filters nothing
# at the database. The failure path's lookup runs on the unique `index_agent_api_keys_on_token_digest`
# that already serves resolution, with `revoked_at` checked on the row it returns. An index here
# would be write cost bought for no reader.
class AddLastRefusedAtToAgentApiKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_api_keys, :last_refused_at, :datetime
  end
end
