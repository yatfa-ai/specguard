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
# meaning. Porting `regenerate!` here would also port `rotated_at` and `rotated_and_unused?`, a pair
# of columns that exist to date the copy on a stranded CI credential.
class UserApiKey < ApplicationRecord
  # Deliberately NOT `ApiKey::TOKEN_PREFIX` with a letter swapped, and deliberately the same LENGTH
  # as it: the two are compared against a caller's string, and a prefix of one that is a prefix of
  # the other would make the discrimination in `Api::BaseController` ambiguous.
  TOKEN_PREFIX = "sgu_"
  TOKEN_BYTES = 24

  belongs_to :user

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
  def self.authenticate(token)
    return nil if token.blank?

    eager_load(:user).merge(User.active).find_by(token_digest: digest(token))
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
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
