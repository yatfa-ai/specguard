# frozen_string_literal: true

require "openssl"

# A CI/agent credential for one repository.
#
# Only the SHA-256 digest is ever persisted. The raw token exists in memory for exactly the
# request that created the key — that is what makes the UI "reveal once": there is no code path,
# anywhere, that can recover it afterwards.
class ApiKey < ApplicationRecord
  TOKEN_PREFIX = "sgk_"
  TOKEN_BYTES = 24

  belongs_to :repository

  # Populated on create only. `nil` on every record loaded from the database.
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

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  # Safe to show anywhere: identifies the key without revealing it.
  def token_hint
    "#{TOKEN_PREFIX}…#{token_digest.last(6)}"
  end

  private

  def assign_token
    @raw_token ||= "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(TOKEN_BYTES)}"
    self.token_digest = self.class.digest(@raw_token)
  end
end
