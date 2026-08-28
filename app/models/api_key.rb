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

  # What a key is called when nobody chose a name for it.
  #
  # Here rather than at any one of the three call sites, because all three mint a key the person
  # never named and the string is what makes those keys recognisably the same thing:
  # `ApiKeysController#api_key_name`'s default (a browser mint with the name field left blank),
  # `Api::V1::UserRepositoriesController::FIRST_KEY_NAME` (an agent registering over the API), and
  # `BulkRegistration`'s per-repository first key (a browser registering a whole organization).
  #
  # It was two literals agreeing by hand until the third caller arrived, and
  # `Api::V1::UserRepositoriesController` already states why the agreement is deliberate: "so a
  # repository registered by an agent and one registered in a browser have identically-named keys
  # rather than two conventions a person has to learn." Three hand-typed copies is three chances to
  # change two of them, and nothing in the suite would see the third drift.
  DEFAULT_NAME = "Default CI Key"

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

  # Rotate this key in place: fresh token, same row. Name, `created_by_user`, `created_at` and
  # `last_used_at` survive, because a rotation is an event on this key rather than a new key plus a
  # revocation.
  #
  # The old digest is OVERWRITTEN, not kept alongside the new one, and `authenticate` resolves a
  # token only by looking its digest up — so the previous token stops authenticating the moment
  # this saves. There is no grace window and no way back to it. Storage stays digest-only: the new
  # plaintext lives in `raw_token`, in memory, for the rest of this request and nowhere else.
  #
  # `rotated_at` is written in the SAME `save!` that swaps the digest, and that is the point of it
  # rather than a detail of it: the row can then never carry a new token beside a `last_used_at`
  # stamped by the old one without also carrying the timestamp that says so.
  #
  # {#rotated_and_unused?} is the predicate the rotated-but-unused state is DERIVED from, and it is
  # where the rule lives — but the column itself is not private to this class. It is also SERVED, by
  # `GET /api/v1/repository`, under both `api_key.rotated_at` and
  # `credential_health.keys[].rotated_at`, and it is read directly by the repository page's
  # api-keys and connect-this-repository partials, which date the stranded-key copy from it. So
  # changing when this is written or cleared moves a published API contract and rendered web copy
  # along with the predicate — the blast radius is not local to this model.
  def regenerate!
    # `assign_token` is idempotent by design, and that is exactly what has to be defeated here:
    # this row is already carrying the token it was minted with.
    @raw_token = nil
    assign_token
    self.rotated_at = Time.current
    save!
    self
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  # WHETHER THIS KEY'S `last_used_at` WAS STAMPED BY A TOKEN THAT NO LONGER EXISTS — the key has
  # been rotated, and nothing has authenticated with the replacement since.
  #
  # This is an ordering comparison between two recorded facts, not a window and not a staleness
  # threshold: `rotated_at` is the instant the old token stopped working, `last_used_at` is the
  # last instant something authenticated, and the only question is which of them is newer. A key
  # whose replacement has reached CI has a use on top and reads normally again immediately — no
  # window to expire, no threshold to cross. Deliberately the same shape as
  # `RejectedIngests#refusing?`, so this page carries ONE rule for "is the newest thing that
  # happened to this pipeline a good thing" rather than one per surface.
  #
  # Both `nil` cases are decided rather than left to a comparison, and they go opposite ways:
  #
  # * `rotated_at` nil is *never rotated*, which is every key that has not been regenerated. There
  #   is no retired token, so no timestamp can be misattributed to one — `false`, and the key reads
  #   exactly as it did before this existed.
  # * `last_used_at` nil is *rotated before it ever authenticated*, and that is not "no comparison"
  #   — it is the state at its purest: a key carrying a replacement token that has never been used,
  #   with not even an inherited timestamp to soften it. `true`, on `refusing?`'s own rule that a
  #   nil counterpart is the worst case.
  #
  # `<=` and not `<`: the question is whether the use is NEWER than the rotation, so a use that is
  # merely simultaneous with it has not cleared it. Nothing hangs on the tie in practice —
  # `authenticate_api_key!` stamps a use strictly after the request that rotated the key committed
  # — but the boundary is stated rather than inherited from an operator.
  def rotated_and_unused?
    return false if rotated_at.nil?
    return true if last_used_at.nil?

    last_used_at <= rotated_at
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
