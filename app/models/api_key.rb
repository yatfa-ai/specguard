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

  # `regenerate!`'s refusal, named once at the top of the class with the other nouns the class
  # exports: rotating a revoked key has no honest outcome, so the method raises this rather than
  # faking a rotation a revoked row cannot carry (see the method for what would break). The
  # controller checks `revoked?` first and answers with a redirect, so in the web flow this raise
  # is the backstop for every caller after that one — exactly the shape `GithubApi`'s error
  # family follows, a controlled refusal a rescue can catch rather than a bare `RuntimeError`
  # nothing can tell apart from a crash.
  Revoked = Class.new(StandardError)

  # What a key is called when nobody chose a name for it.
  #
  # Here rather than at any one of the mint sites, because each mints a key the person never named
  # and the string is what makes those keys recognisably the same thing:
  # `ApiKeysController#api_key_name`'s default (a browser mint with the name field left blank),
  # `Api::V1::UserRepositoriesController::FIRST_KEY_NAME` (an agent registering over the API),
  # `BulkRegistration`'s per-repository first key (a browser registering a whole organization), and
  # `Api::V1::UserRepositoryApiKeysController#key_name` (an agent minting a subsequent key).
  #
  # It was two literals agreeing by hand until the third caller arrived, and
  # `Api::V1::UserRepositoriesController` already states why the agreement is deliberate: "so a
  # repository registered by an agent and one registered in a browser have identically-named keys
  # rather than two conventions a person has to learn." Every default-naming mint site in Ruby reads
  # this constant rather than repeating the literal, so a rename cannot leave two Ruby paths
  # spelling the default differently. The one hand-typed copy of the literal outside this constant
  # and the specs is the `api_keys.name` column default (see `db/schema.rb`) — a rename here does
  # NOT move it, and a mint that passes no name at all takes that column default rather than this
  # constant.
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

  # The longest `name` a mint accepts — measured against the budget that actually binds it, never
  # estimated (SPGD-1080's rule).
  #
  # ## The budget
  #
  # This app has no `config/initializers/session_store.rb`, so the session — the reveal flash
  # included — is Rails' default cookie store, whose ceiling is
  # `ActionDispatch::Cookies::MAX_COOKIE_SIZE` (4,096 bytes of cookie name + value). A web mint
  # commits the key row on `save`, writes the reveal flash (`revealed_api_key` +
  # `revealed_api_key_name`) and a notice into the session, and redirects — and the session cookie
  # only serializes afterwards, at `commit_session`. An oversize flash therefore does not answer
  # as a validation error: it raises `CookieOverflow` at `commit_session`, a 500 with the key row
  # already committed and the reveal-once token lost with the overflowing cookie — nothing can
  # re-serve that token afterwards, because only the SHA-256 digest persists. The bound lives
  # HERE, in the data, on the same refuse-don't-coerce rule the NUL validation below states; the
  # length refusal lands in the refusal channel every mint surface already renders — the web
  # else branches, the API mint's `render_bad_request`.
  #
  # ## The measurement
  #
  # Sizes below are the ceiling check's OWN arithmetic — `cookie_name.bytesize + value.bytesize`
  # on the serialized value, i.e. `EncryptedKeyRotatingCookieJar#check_for_overflow!`'s inputs —
  # recorded by wrapping that check around a real `POST /repositories/:id/api_keys` mint in a
  # signed-in spec session. (The Set-Cookie line runs ~110-200B above the guard at these sizes —
  # wire escaping plus the `; path=/; HttpOnly;` attributes — but the guard is what actually
  # raises, so the table reads the guard.)
  #
  #   name bytes | guard B | outcome at that name
  #   -----------|---------|------------------------------------------------------
  #             2 |     774 | baseline mint, name "CI"
  #           256 |   1,230 | this cap, ASCII — Set-Cookie line 1,343B
  #         1,024 |   2,594 | this cap's worst byte shape (256 four-byte
  #                     characters still count as 256) — line 2,787B
  #         1,860 |   4,078 | last name the spec-session ceiling tolerates
  #         1,870 |   4,098 | ActionDispatch::Cookies::CookieOverflow
  #
  # The `/account` mints measure within ~20B of the repository rows at this cap (`sgu_`/`sga_`:
  # 1,246B / 1,250B) — same reveal-flash shape, same cookie, same budget.
  #
  # ## Why 256
  #
  # A key name is a label, and 256 characters is already several times the longest realistic
  # credential label. The cookie only binds near 1,860-byte names in a spec session — lower in a
  # real one, which measures heavier (~200B on SPGD-1075's live measurement) — so a cap at that
  # boundary would spend the whole budget on a label. 256 is chosen inside the measured budget
  # instead, leaving ~2.8KB (and, at the worst four-byte-per-character shape, ~1.5KB) of headroom
  # for everything else a real session carries today and may carry tomorrow. A constant raised
  # past where the cookie binds fails the budget example pinned on THIS constant
  # (`spec/requests/api_keys_spec.rb`) — a mint at the raised cap either raises `CookieOverflow`
  # in the example or drives the recorded guard total across `MAX_COOKIE_SIZE` — instead of
  # surfacing in production as the post-commit 500 this cap exists to prevent.
  NAME_MAX_LENGTH = 256

  validates :token_digest, presence: true, uniqueness: true
  # A NUL in `name` is refused, not scrubbed: Postgres cannot store that character, so a row that
  # passed validation would die at INSERT with `ArgumentError: string contains null byte` and the
  # mint would surface as a 500 with nothing written. The same refuse-don't-coerce rule
  # `Ingest::Payload` states and `Repository` follows for `github_full_name` (see its `NUL`
  # comment). There is no uniqueness validator on `name`, so — unlike `Repository` — no validator
  # can run a query with the NUL before this one answers.
  validates :name, presence: true,
                   format: { without: /\u0000/, message: "must not contain a NUL character" }
  # `NAME_MAX_LENGTH` extends the same rule to length: an over-budget name is refused with the
  # model's sentence ("Name is too long (maximum is … characters)") rather than truncated or
  # committed. Unlike the NUL check it is scoped to mints and name changes, because `regenerate!`
  # saves the row with its name untouched and rotation is the only recovery path for a lost token
  # (the row holds only the SHA-256 digest). Unscoped, the cap would break that recovery for any
  # row minted before it existed — the API mint accepted any length, the web mint ~1,860
  # characters — turning `save!` in `regenerate!` into `RecordInvalid`. Legacy over-cap rows are
  # therefore intentionally left valid: the cap binds new rows and name changes only.
  validates :name, length: { maximum: NAME_MAX_LENGTH },
                   if: -> { new_record? || will_save_change_to_name? }

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  # Resolve a Bearer token to its key. O(1) on the unique digest index — the raw token is never
  # compared against anything, only its digest is looked up.
  #
  # `live` only, and that is the security half of the retirement: `revoke!` keeps the row (so a
  # revoked token stays attributable), which means the row would otherwise keep resolving. The
  # filter rides the same `find_by` — still one indexed read on the unique digest index, and the
  # security half holds by placement rather than by caller count: the `live` filter lives inside
  # the model, so it covers every caller of this method, present and future —
  # `Api::BaseController#authenticate_api_key!` and
  # `Ingest::BoundaryRefusalRecorder#resolve_repository` among them — and there is no
  # per-call-site re-statement of the `live` rule that could drift.
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
  # A REVOKED key refuses the gesture outright (`Revoked`), and the guard reads FIRST so nothing
  # on the row moves. Rotation on a retired row has no honest outcome on either half of the
  # retirement: the replacement `authenticate` resolves would hand out a token that can never
  # work (the method filters to `live`), revealed once through a flash that says to copy it; and
  # overwriting `token_digest` would erase the only handle
  # `Api::BaseController#attribute_refused_revocation` has for attributing a still-presented
  # token to this row — the "Revoked and still presented" evidence would silently become an
  # unattributable 401. The refusal mirrors `revoke!`'s first-wins guard read from the other
  # side: revocation is terminal, so the gesture that would quietly rewrite its evidence raises
  # before touching a column.
  #
  # {#rotated_and_unused?} is the predicate the rotated-but-unused state is DERIVED from, and it is
  # where the rule lives — but the column itself is not private to this class. It is also SERVED, by
  # `GET /api/v1/repository`, under both `api_key.rotated_at` and
  # `credential_health.keys[].rotated_at`, and it is read directly by the repository page's
  # api-keys and connect-this-repository partials, which date the stranded-key copy from it. So
  # changing when this is written or cleared moves a published API contract and rendered web copy
  # along with the predicate — the blast radius is not local to this model.
  def regenerate!
    # The guard is deliberately the method's first statement: by the time it passes, nothing has
    # been cleared, assigned or stamped, so a refused call leaves `token_digest` and `rotated_at`
    # exactly as it found them.
    raise Revoked, "cannot regenerate a revoked key — a revoked key never authenticates again" if revoked?

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
  # validation this gesture does not carry. Idempotent — FIRST REVOCATION WINS: a replayed revoke
  # is a no-op and never re-stamps `revoked_at`. A replay IS reachable (the API and web destroy
  # actions look the row up without the `live` scope, and a retried DELETE answers 204 by design),
  # and a re-stamp would make `revoked_at` newer than `last_refused_at`, contradicting
  # `revoked_and_still_presented?`'s "refusal stamp always postdates revocation" and losing the
  # offboarding date.
  #
  # `revoked_at` is never cleared by anything: there is no un-revoke, and a token that was retired
  # once can never authenticate again (`authenticate` filters to `live`).
  def revoke!
    update_column(:revoked_at, Time.current) unless revoked?
    self
  end

  # Whether THIS row has been retired. Consumers that load ONE side only read it at the SQL layer
  # through the `live`/`revoked` scopes — the "minted N keys" badge is the standing example —
  # while every surface that needs BOTH halves loads the rows and reads the split through
  # `ApiKeyPartition`, the seam that owns the live/revoked/stranded/presented-revoked partition
  # built from this predicate. `RepositoriesController#show` and
  # `RepositoryOverview#serialized_credential_health` load ALL of a repository's rows, and the
  # repositories grid loads both halves for its page's repositories through `api_key_rows`,
  # grouped per repository by `ApiKeyPartition.grouped_by_repository` — all precisely so that
  # partition can serve the presented-revoked half, which a `WHERE revoked_at IS NULL` here would
  # have filtered out before it could be seen — and each reaches the split through the seam
  # rather than spelling it at its own site. `spec/models/api_key_partition_spec.rb` holds the
  # repo-wide property that they still do.
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
