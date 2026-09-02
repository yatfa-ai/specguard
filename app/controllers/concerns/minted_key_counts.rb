# frozen_string_literal: true

# THE SINGLE READER FOR "HOW MANY LIVE API KEYS DID THESE PEOPLE MINT", extracted from
# `MembershipsController` when a second controller needed the same count.
#
# `Revoking/leaving a membership deliberately does not touch the API keys that member minted (see
# `User has_many :created_api_keys, dependent: :nullify`), so every surface that ends an access —
# the owner's members table, the owner's Revoke dialog and flash, a member's own Leave dialog and
# flash — has to quote how many keys the act leaves behind. Those surfaces live on two controllers
# (`MembershipsController` renders the members page and serves both removals; `RepositoriesController`
# renders the Leave dialog beside the "Your access" row), and one count with two implementations is
# two answers that can drift, so the reader is a concern both include.
#
# `user_id => live key count`, for the whole batch in ONE grouped query — the same N+1 discipline
# as `RepositoriesController#shared_permissions` ("the same answer in a single query"), because a
# per-row count would cost one query per member.
#
# Scoped through `repository.api_keys`, so it can never read another repository's keys, and it
# counts what is *live*. LIVE is a real predicate since SPGD-804's retirement split, not a
# description of deletion: a revoked row is retained, and counting it would tell whoever is
# reading the dialog — an owner revoking a colleague, or a member leaving — that keys "keep
# authenticating" when every one of them has been retired. The disclosure's premise is a key
# that will SURVIVE the access ending, and a revoked key is not one.
#
# The `keys.manage` gate is the load-bearing line, and it lives HERE rather than at the call sites
# for the same reason `current_repository` resolves and authorizes together: a caller that forgets
# it is a leak, and every caller needs it. `members.manage` and `keys.manage` are independent
# permissions, so a viewer can hold the members page — or reach repositories#show, which gates at
# `:view` — without holding any right to key metadata, and `RepositoriesController#key_count_visible?`
# already states the rule this obeys: "repositories#show gates the whole API keys panel behind
# `keys.manage`, so a bare count would leak past the same line." A count in a dialog on that page is
# the same count. An empty hash makes every surface downstream degrade to the zero-key wording,
# which is exactly right: a viewer who may not know the number should be told nothing, not told less.
#
# The gate also keeps any deep link honest. The members page's key badge points at `#api-keys` on
# repositories#show, a panel that renders only under the same `keys.manage` — so gating on anything
# wider would render an affordance that lands on a page where the panel, the anchor and the Revoke
# button it promises all do not exist.
#
# Ordering is load-bearing and pinned by the query-count examples: the gate returns `{}` BEFORE the
# `api_keys` query runs, so a viewer without `keys.manage` is charged nothing at all —
# repositories#show's absolute budgets count on that.
#
# `repository_policy` is memoized per repository and already populated by `current_repository` in
# every caller, so this asks the database nothing for the gate itself.
module MintedKeyCounts
  extend ActiveSupport::Concern

  private

  # `user_id => live key count` for `user_ids` on `repository`, `{}` unless the caller holds
  # `keys.manage` on it or `user_ids` is empty.
  def keys_minted_by(repository, user_ids)
    return {} unless repository_policy(repository).can?(:keys_manage)
    return {} if user_ids.empty?

    repository.api_keys.live.where(created_by_user_id: user_ids).group(:created_by_user_id).count
  end
end
