# frozen_string_literal: true

require "openssl"

# A credential that speaks for a PERSON, across every repository that person may open — the
# account-level sibling of `ApiKey`, which speaks for exactly one repository.
#
# Storage is digest-only on the same terms as `ApiKey`: the raw token exists in memory for exactly
# the request that minted it, and no code path anywhere can recover it afterwards. That is what
# makes the account page's reveal-once true rather than merely stated.
#
# ## The prefix is load-bearing, not decoration
#
# `sgu_` is what tells this credential apart from a repository key BEFORE either table is read.
# One `Authorization: Bearer` header now addresses two credential tables, and the naive
# implementation probes both — two indexed reads on every request, and a token that is valid
# nowhere paying for both of them. `Api::BaseController#authenticate_api_key!` discriminates on the
# prefix first, so resolution stays the single indexed read `ApiKey.authenticate` has always been,
# and a token presented to the surface it does not belong to is refused without a lookup at all.
#
# ## There is no `regenerate!`, deliberately
#
# `ApiKey#regenerate!` rotates a repository key in place because that key is frequently wired into
# a CI pipeline that names it by nothing but its row — rotating it keeps the pipeline pointed at
# something. A user key has no such fixture: it is held by a person, on a laptop or in an agent, and
# the answer to "I lost it" is to mint another and revoke this one. Two rows, two names, and an
# audit trail that says which was retired when — rather than one row whose history quietly changes
# meaning. That trail is real now (`revoke!` stamps `revoked_at` and the row is kept — SPGD-943);
# it was this class's own promise before it was its behaviour. Porting `regenerate!` here would
# also port `rotated_at` and `rotated_and_unused?`, a pair of columns that exist to date the copy
# on a stranded CI credential.
class UserApiKey < ApplicationRecord
  # Deliberately NOT `ApiKey::TOKEN_PREFIX` with a letter swapped, and deliberately the same LENGTH
  # as it: the two are compared against a caller's string, and a prefix of one that is a prefix of
  # the other would make the discrimination in `Api::BaseController` ambiguous.
  TOKEN_PREFIX = "sgu_"
  TOKEN_BYTES = 24

  belongs_to :user

  # The retirement split, named once and used everywhere a caller needs one side of it — the same
  # scopes `ApiKey` carries, and the same NO `default_scope` rule (stated where `ApiKey` names its
  # own): the distinction exists precisely so each reader can pick a side and say so, and a default
  # would silently flip `authenticate` and every future reader without any of them naming the
  # choice. `revoked_at` is written by `revoke!` and never cleared: a revoked key cannot come back.
  scope :live, -> { where(revoked_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  # Populated by the request that minted this row, and `nil` on every record loaded from the
  # database — the same shape as `ApiKey#raw_token`, for the same reason.
  attr_reader :raw_token

  before_validation :assign_token, on: :create

  validates :token_digest, presence: true, uniqueness: true
  validates :name, presence: true

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  # Resolve a Bearer token to its key, and to a person who is still allowed to be one.
  #
  # `User.active` is joined in HERE, at the resolution site, rather than checked by a caller. An API
  # key does not expire the way a session does: `ApplicationController#current_user` scopes to
  # `User.active` precisely so that archiving somebody takes effect on the session they are ALREADY
  # holding, and a user key that outlived archiving would be a strictly worse version of the hole
  # that scope was written to close — a credential with no expiry at all, held by somebody the
  # offboarding control has already refused. So an archived owner's token resolves to nothing, and
  # the endpoint answers 401 with no more detail than it gives a token that never existed.
  #
  # Still one indexed read, and `eager_load` rather than `joins` is what keeps it true. Both spell
  # the same JOIN and both let `merge(User.active)` land its `archived_at IS NULL` in the `WHERE`,
  # so they refuse an archived owner identically. They differ in what they leave behind: `joins`
  # visits the `users` row to filter on it and then discards it, so the very next caller —
  # `Api::BaseController#bind_principal`, on EVERY authenticated request — reads that same row a
  # second time by primary key. `eager_load` selects its columns in the one statement and hands
  # back a record whose `user` is already `loaded?`, so binding the principal costs no query at all.
  # The join has to be paid for either way; this is the spelling that does not pay for it twice.
  #
  # `spec/models/user_api_key_spec.rb` pins both halves — one statement, and a `user` that reads
  # zero — and `spec/requests/api/v1/credential_seam_spec.rb` counts the whole request against
  # BOTH tables so the claim is measured over HTTP rather than asserted in this comment.
  #
  # `live` only, and that is the security half of the retirement (SPGD-943): `revoke!` keeps the
  # row — retention is what makes a revoked token attributable — so the row would otherwise keep
  # resolving forever. The filter rides the same `find_by`, so everything the paragraphs above
  # measure survives intact: still one statement, still one indexed read on the unique digest
  # index, still the ONLY resolution site for a user credential. The refusal of a revoked token
  # then has somewhere to land — `Api::BaseController`'s failure path finds this same row on the
  # digest and stamps `last_refused_at` — which is the whole point of keeping it.
  def self.authenticate(token)
    return nil if token.blank?

    live.eager_load(:user).merge(User.active).find_by(token_digest: digest(token))
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  # Retire this key: the token stops authenticating, and the ROW STAYS — the `destroy!` this
  # method retired is exactly the move that made the two promises in this file's header false.
  # The reason for retention is attribution, the same reason `ApiKey#revoke!` gives: a hard delete
  # made a revoked token's 401 unreportable — `authenticate` resolving nothing leaves nothing to
  # attach a record to, so a revoked key presented by an agent or an MCP client read, at best,
  # "this was never a key". Keeping the row keeps the artifact the failure path needs (see
  # `Api::BaseController#attribute_refused_revocation`, which stamps `last_refused_at` on exactly
  # this row), and is what finally makes "an audit trail that says which was retired when" true.
  #
  # `update_column` rather than `save!`, exactly as `touch_last_used!` and `ApiKey#revoke!` both
  # do: revocation is a stamp on the row's existing state, not a validation event, and it must not
  # be able to fail on a validation this gesture does not carry. Idempotent — a replayed DELETE
  # re-stamps, which is unobservable, because the Revoke button is rendered only on live keys.
  #
  # `revoked_at` is never cleared by anything: there is no un-revoke, and a token that was retired
  # once can never authenticate again (`authenticate` filters to `live`).
  def revoke!
    update_column(:revoked_at, Time.current)
    self
  end

  # Whether THIS row has been retired. Read by the account page, which must show retired rows AS
  # retired (and offer no Revoke on them), via this predicate once the rows are loaded and the
  # `live`/`revoked` scopes at the SQL layer.
  def revoked?
    revoked_at.present?
  end

  # Whether a client is STILL PRESENTING this retired token — the platform has seen the digest it
  # carries arrive and be refused since `revoke!` stamped the retirement. The epistemics are
  # `ApiKey#revoked_and_still_presented?`'s verbatim: there is no ordering question (a refusal can
  # only be stamped on an already-revoked row, so the stamp always postdates the revocation) and
  # no recovery — a revoked token never authenticates again, so the state has no window to clear
  # and no threshold to cross. What the pair cannot prove is that a client is presenting the token
  # AT THIS MOMENT: `last_refused_at` is the last time the platform saw it, so a client that gave
  # up hours ago reads the same as one presenting right now. Every surface that renders this state
  # serves the recency beside it rather than letting the badge claim a present tense the data does
  # not carry.
  def revoked_and_still_presented?
    revoked? && last_refused_at.present?
  end

  def touch_last_refused!
    update_column(:last_refused_at, Time.current)
  end

  # Safe to show anywhere: identifies the key without revealing it. Same construction as
  # `ApiKey#token_hint`, carrying THIS class's prefix so a person holding both kinds can tell which
  # list they are looking at.
  def token_hint
    "#{TOKEN_PREFIX}…#{token_digest.last(6)}"
  end

  private

  # `||=` for the reason `ApiKey` gives: a `valid?` before the `save` runs the callback twice, and
  # without it the second run would swap in a different token under anyone who had already read
  # `raw_token`. Nothing here ever needs to defeat that idempotence — there is no `regenerate!`.
  def assign_token
    @raw_token ||= "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(TOKEN_BYTES)}"
    self.token_digest = self.class.digest(@raw_token)
  end
end
