# frozen_string_literal: true

# The retirement half of a credential row, written ONCE for each of the key models (`ApiKey`,
# `UserApiKey`, `AgentApiKey`): the `live`/`revoked` split and the four methods that read and
# write `revoked_at` / `last_refused_at`.
#
# It is one module because the same defect had to be fixed twice, as separate changes — `revoke!`
# re-stamping `revoked_at` on an already-revoked row was repaired on two of the models, and the
# third, a hand-copied twin nobody touched, needed a second wave. A fix to the retirement
# mechanism now lands here, once. Including a model must have `revoked_at` and `last_refused_at`
# columns; nothing else is assumed of it. Token generation, digests, hints, `touch_last_used!` and
# `authenticate` stay on each model — they differ per credential and are not part of retirement.
#
# ## The scopes
#
# `live` and `revoked` partition the table. NO `default_scope`, on purpose: the distinction exists
# precisely so each reader picks a side and says so, and a default would silently flip
# `authenticate` and every other reader without any of them naming the choice. `revoked_at` is
# written by `revoke!` and never cleared: a revoked key cannot come back.
#
# ## Retirement is not deletion
#
# `revoke!` retires a key — the token stops authenticating — and the ROW STAYS. The reason is
# attribution: a hard delete made a revoked token's 401 unreportable, because `authenticate`
# resolving nothing leaves nothing to attach a record to. Keeping the row keeps the artifact the
# failure path needs (`Api::BaseController` stamps `last_refused_at` on exactly this row), and
# keeps the key history truthful instead of amputated.
#
# `update_column` rather than `save!`, exactly as each model's `touch_last_used!` does: revocation
# is a stamp on the row's existing state, not a validation event, and it must not be able to fail
# on a validation this gesture does not carry.
#
# ## First revocation wins
#
# A replayed `revoke!` is a no-op and never re-stamps `revoked_at`. A replay IS reachable — the
# destroy actions look the row up without the `live` scope, and a retried DELETE answers 204 by
# design — and a re-stamp would make `revoked_at` newer than `last_refused_at`, contradicting
# `revoked_and_still_presented?`'s "refusal stamp always postdates revocation" and losing the
# offboarding date. `revoked_at` is never cleared by anything: there is no un-revoke, and a token
# retired once can never authenticate again (`authenticate` filters to `live`).
module CredentialRetirement
  extend ActiveSupport::Concern

  included do
    scope :live, -> { where(revoked_at: nil) }
    scope :revoked, -> { where.not(revoked_at: nil) }
  end

  # Retire this key. Idempotent — see "First revocation wins" above. Returns the row either way.
  def revoke!
    update_column(:revoked_at, Time.current) unless revoked?
    self
  end

  # Whether THIS row has been retired. Consumers that load ONE side only read it at the SQL layer
  # through the `live`/`revoked` scopes; a surface that needs BOTH halves loads the rows and reads
  # the split through this predicate (for `ApiKey`, via `ApiKeyPartition`).
  def revoked?
    revoked_at.present?
  end

  # Whether a client is STILL PRESENTING this retired token — the platform has seen the digest it
  # carries arrive and be refused since `revoke!` stamped the retirement.
  #
  # There is no ordering question here (a refusal can only be stamped on an already-revoked row, so
  # the stamp always postdates the revocation) and there is no recovery — a revoked token never
  # authenticates again, so the state has no window to clear and no threshold to cross. What the
  # pair cannot prove is that a client is presenting the token AT THIS MOMENT: `last_refused_at` is
  # the last time the platform saw it, so a client that gave up hours ago reads the same as one
  # presenting right now. Every surface that renders this state serves the recency beside it
  # rather than letting the badge claim a present tense the data does not carry.
  def revoked_and_still_presented?
    revoked? && last_refused_at.present?
  end

  # Stamp that a refused presentation of this (retired) token just arrived. A stamp on existing
  # state, not a validation event — `update_column`. The failure path pays this at most once per
  # refused presentation.
  def touch_last_refused!
    update_column(:last_refused_at, Time.current)
  end
end
