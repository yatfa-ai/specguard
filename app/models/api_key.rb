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

  # Who minted the key, recorded at create time — attribution outlives every later event on the row
  # (see `revoke!`, which retires a key without deleting it). `optional` on purpose: a key outlives
  # the person who minted it (see `User has_many :created_api_keys, dependent: :nullify`), and keys
  # minted before this column existed, or through any non-UI path, legitimately have no creator.
  belongs_to :created_by_user, class_name: "User", optional: true

  # The retirement split, named once and used everywhere a caller needs one side of it. NO
  # `default_scope` — the distinction exists precisely so each reader can pick a side and say so,
  # and a default would silently flip `authenticate`, `MintedKeyCounts#keys_minted_by` and
  # every future reader without any of them naming the choice. `revoked_at` is written by `revoke!`
  # and never cleared: a revoked key cannot come back.
  scope :live, -> { where(revoked_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }

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
  #
  # `live` only, and that is the security half of the retirement: `revoke!` keeps the row (so a
  # revoked token stays attributable), which means the row would otherwise keep resolving. The
  # filter rides the same `find_by` — still one indexed read on the unique digest index, and still
  # the ONLY resolution site for a repository credential (verified by grep: the sole caller is
  # `Api::BaseController#authenticate_api_key!`).
  def self.authenticate(token)
    return nil if token.blank?

    live.find_by(token_digest: digest(token))
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

  # Retire this key: the token stops authenticating, and the ROW STAYS. The replacement for the
  # `destroy!` this method retired, and the reason it exists is attribution: a hard delete made a
  # revoked token's 401 unreportable — `authenticate` resolving nothing leaves nothing to attach a
  # record to, so a pipeline presenting the dead token read "Not connected yet" on a page that had
  # no way to know why. Keeping the row keeps the artifact the failure path needs (see
  # `Api::BaseController`, which stamps `last_refused_at` on exactly this row), and keeps the
  # repository's key history truthful instead of amputated.
  #
  # `update_column` rather than `save!`, exactly as `touch_last_used!` does: revocation is a stamp
  # on the row's existing state, not a validation event, and it must not be able to fail on a
  # validation this gesture does not carry. Idempotent — a replayed DELETE re-stamps, which is
  # unobservable, because the button is rendered only on live keys.
  #
  # `revoked_at` is never cleared by anything: there is no un-revoke, and a token that was retired
  # once can never authenticate again (`authenticate` filters to `live`).
  def revoke!
    update_column(:revoked_at, Time.current)
    self
  end

  # Whether THIS row has been retired. Read by every consumer that must see live keys only —
  # `RepositoriesController#show`'s partition, `RepositoryOverview#serialized_credential_health`,
  # the "minted N keys" badge — via the `live`/`revoked` scopes at the SQL layer and this predicate
  # once the rows are loaded.
  def revoked?
    revoked_at.present?
  end

  # Whether a client is STILL PRESENTING this retired token — the platform has seen the digest it
  # carries arrive and be refused since `revoke!` stamped the retirement.
  #
  # The epistemics are the same as `rotated_and_unused?`'s, read in the other direction: there is
  # no ordering question here (a refusal can only be stamped on an already-revoked row, so the
  # stamp always postdates the revocation) and there is no recovery — a revoked token never
  # authenticates again, so the state has no window to clear and no threshold to cross. What the
  # pair cannot prove is that a client is presenting the token AT THIS MOMENT: `last_refused_at` is
  # the last time the platform saw it, so a pipeline that gave up hours ago reads the same as one
  # presenting right now. Every surface that renders this state serves the recency beside it rather
  # than letting the badge claim a present tense the data does not carry.
  def revoked_and_still_presented?
    revoked? && last_refused_at.present?
  end

  def touch_last_refused!
    update_column(:last_refused_at, Time.current)
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
