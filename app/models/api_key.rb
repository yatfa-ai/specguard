# frozen_string_literal: true

require "openssl"

# A CI/agent credential for one repository.
#
# Only the SHA-256 digest is ever persisted. The raw token exists in memory for exactly the
# request that minted it — that is what makes the UI "reveal once": there is no code path,
# anywhere, that can recover it afterwards. A key is minted on create and re-minted on every
# `regenerate!`; each minting is revealed for that one request and never again.
class ApiKey < ApplicationRecord
  TOKEN_PREFIX = "sgk_"
  TOKEN_BYTES = 24

  belongs_to :repository

  # Who minted the key, recorded at create time — attribution is not recoverable afterwards, since
  # revoking a key deletes the row outright. `optional` on purpose: a key outlives the person who
  # minted it (see `User has_many :created_api_keys, dependent: :nullify`), and keys minted before
  # this column existed, or through any non-UI path, legitimately have no creator.
  belongs_to :created_by_user, class_name: "User", optional: true

  # Populated by whichever request minted the current token — `create`, or `regenerate!`. `nil` on
  # every record loaded from the database.
  attr_reader :raw_token

  before_validation :assign_token, on: :create

  validates :token_digest, presence: true, uniqueness: true
  validates :name, presence: true

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  # Resolve a Bearer token to its key. O(1) on the unique digest index — the raw token is never
  # compared against anything, only its digest is looked up.
  def self.authenticate(token)
    return nil if token.blank?

    find_by(token_digest: digest(token))
  end

  # Rotate this key in place: fresh token, same row. Name, `created_by_user` and `created_at`
  # survive, because a rotation is an event on this key rather than a new key plus a revocation.
  #
  # The old digest is OVERWRITTEN, not kept alongside the new one, and `authenticate` resolves a
  # token only by looking its digest up — so the previous token stops authenticating the moment
  # this saves. There is no grace window and no way back to it. Storage stays digest-only: the new
  # plaintext lives in `raw_token`, in memory, for the rest of this request and nowhere else.
  def regenerate!
    # `assign_token` is idempotent by design, and that is exactly what has to be defeated here:
    # this row is already carrying the token it was minted with.
    @raw_token = nil
    assign_token
    save!
    self
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  # Safe to show anywhere: identifies the key without revealing it. Derived from the digest, so it
  # tracks a rotation — after `regenerate!` it fingerprints the new token, not the retired one.
  def token_hint
    "#{TOKEN_PREFIX}…#{token_digest.last(6)}"
  end

  private

  # `||=` makes this idempotent: a `valid?` before the `save` runs the callback twice, and without
  # it the second run would swap in a different token under anyone who had already read
  # `raw_token`. `regenerate!` clears the ivar precisely to defeat that.
  def assign_token
    @raw_token ||= "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(TOKEN_BYTES)}"
    self.token_digest = self.class.digest(@raw_token)
  end
end
