# frozen_string_literal: true

# A human, identified by their GitHub OAuth identity. `github_uid` is the stable key — a user may
# rename their GitHub handle and must still resolve to the same row.
class User < ApplicationRecord
  # A GitHub login, as GitHub itself constrains it: alphanumerics and single hyphens, no leading or
  # trailing hyphen, 39 characters at most. Applied to the *query* in `resolve_by_handle`, never as
  # a validation — see the comment there.
  HANDLE_FORMAT = /\A[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?\z/

  # Either of these lets the app read a repository and the caller's permission level on it, which
  # is all ownership verification needs. `repo` also covers private repositories; `public_repo`
  # does not, and a user who grants only that will simply not see their private repositories in
  # the registration list. Both are accepted so the narrower grant is a usable answer rather than
  # a dead end. Neither is requested at sign-in — see `SpecGuard::GithubOauth`.
  GITHUB_REPOSITORY_SCOPES = Set["repo", "public_repo"].freeze

  # The four-way answer from `User.resolve_by_handle`. A handle is deliberately not unique across
  # rows, so a caller that gets a bare `User` back cannot tell "this is the person you named" from
  # "this is one of several people who might be". This makes the difference impossible to ignore.
  #
  # `:malformed` is separate from `:not_found` for the same reason: "that is not a GitHub handle"
  # and "nobody has signed in with that handle" are different facts about the world and want
  # different answers from a caller. Collapsing them would tell an owner who pasted a profile URL
  # to go ask a colleague to re-authenticate — advice that sends them to fix the wrong thing.
  Resolution = Data.define(:status, :user, :match_count) do
    def found? = status == :found
    def not_found? = status == :not_found
    def ambiguous? = status == :ambiguous
    def malformed? = status == :malformed
  end

  # `:restrict_with_error`, NOT `:destroy`. These two are the associations a person *owns*, and
  # cascading from them deletes other people's data: a user's repositories carry every
  # collaborator's membership on them and every byte of telemetry beneath them (see `Repository`'s
  # own cascade), so a single `user.destroy` would take a colleague's access and a repository's
  # whole history with it.
  #
  # The asymmetry with `Repository` is deliberate, and is the point rather than an oversight.
  # Destroying a *repository* still cascades into its api_keys, spec_observations, test_runs,
  # spec_intents and memberships, because those genuinely belong to it and go when it goes.
  # Destroying the *person* does not, because what hangs off them belongs to their colleagues.
  # `:nullify` is not an option here either — `repositories.user_id` and
  # `repository_memberships.user_id` are both `NOT NULL` (db/schema.rb), so there is no "unknown
  # owner" state for these rows the way there is for the attribution columns below.
  #
  # `_with_error` rather than `_with_exception`: `destroy` returns `false` with the reason on
  # `errors[:base]`, which is the ordinary Rails shape a future "remove user" screen can render;
  # `destroy!` still raises `ActiveRecord::RecordNotDestroyed`. Be honest about what that buys — it
  # makes a user undestroyable the moment they register a repository or are invited to one, so in
  # practice the only row this still permits deleting is someone who signed in and went no further.
  # That is deliberate: the answer for a departing user is archive/disable, not delete, and this
  # holds the line until that path exists. Nothing in `app` or `lib` calls `User#destroy` today.
  #
  # The note that used to sit here — that both sides must declare `:destroy` or the foreign key
  # fails on destroy — no longer applies: `:restrict_with_error` aborts before any DELETE is issued,
  # so the FK is never reached. It remains the second line of defence for a callback-bypassing
  # `user.delete`, which raises `ActiveRecord::InvalidForeignKey` rather than silently orphaning.
  has_many :repositories, dependent: :restrict_with_error
  has_many :repository_memberships, dependent: :restrict_with_error
  # Repositories shared *with* this user — deliberately separate from `repositories`, which stays
  # "repositories this user owns" and is what RepositoriesController#index still lists.
  has_many :member_repositories, through: :repository_memberships, source: :repository

  # `:nullify`, NOT `:destroy` — an API key belongs to the repository, not to whoever minted it.
  # A collaborator's key is frequently the credential the owner's CI authenticates with, so deleting
  # the collaborator must degrade the key to "unknown creator", never revoke it.
  has_many :created_api_keys, class_name: "ApiKey", foreign_key: :created_by_user_id,
                              dependent: :nullify, inverse_of: :created_by_user

  # `:nullify` for the same reason as `created_api_keys`, one step further: a membership is somebody
  # *else's* access. Deleting the person who granted it must forget who granted it, never revoke the
  # colleague who was granted it — and it must not be confused with `repository_memberships` above,
  # which is this user's *own* access and, far from going away with them, is now one of the two
  # things that stops them being deleted at all.
  has_many :granted_repository_memberships, class_name: "RepositoryMembership",
                                            foreign_key: :granted_by_user_id,
                                            dependent: :nullify, inverse_of: :granted_by_user

  # The OAuth access token GitHub issued at this user's last authorization. Encrypted at rest
  # (keys: config/initializers/active_record_encryption.rb) because it can read the repository
  # metadata of whoever granted it — including private repositories, once the elevated scope is
  # granted. Written only by `assign_github_authorization`; read only by `GithubApi.for`.
  encrypts :github_access_token

  before_validation :normalize_github_handle

  validates :github_uid, presence: true, uniqueness: true
  validates :github_handle, presence: true

  # Resolve a user-typed GitHub handle. The only sanctioned way to look a user up by handle.
  #
  # `github_handle` is NOT unique, and must not be: a row holds whatever handle its owner had at
  # their last sign-in (`from_github_omniauth` keys on `github_uid`), so when GitHub frees a
  # renamed handle and someone else claims it, two rows legitimately carry the same string. A
  # `find_by` there returns an arbitrary row — which, in a feature that grants access to a private
  # repository, silently grants it to a stranger. So ambiguity is reported at read time, never
  # forbidden at write time (a uniqueness constraint would instead make sign-in raise for the
  # innocent second user).
  #
  # Returns a `Resolution`; never raises, and never picks a row out of several.
  def self.resolve_by_handle(handle)
    normalized = normalize_handle(handle)

    # A string GitHub could not have issued as a login cannot be anyone's handle — so this is a
    # statement about the *query*, not about who has signed in, and is reported as such. This is
    # also what keeps a fallback-derived handle (`from_github_omniauth` may store a display name
    # such as "The Octocat") from being resolvable as an identity.
    return Resolution.new(status: :malformed, user: nil, match_count: 0) unless normalized&.match?(HANDLE_FORMAT)

    matches = where(github_handle: normalized).order(:id).to_a

    case matches.length
    when 0 then Resolution.new(status: :not_found, user: nil, match_count: 0)
    when 1 then Resolution.new(status: :found, user: matches.first, match_count: 1)
    else Resolution.new(status: :ambiguous, user: nil, match_count: matches.length)
    end
  end

  # Canonical stored/queried form of a handle. GitHub logins preserve display case but are
  # case-insensitively unique, so storing the canonical form keeps lookups plain equality against
  # the index rather than a `LOWER()` scan.
  def self.normalize_handle(handle) = handle.to_s.strip.downcase.presence

  # GitHub returns granted scopes as a comma-separated string whose spacing and ordering are not
  # promised. Stored in one canonical form so `github_scopes` is a plain split and two grants of
  # the same scopes compare equal.
  def self.normalize_scopes(scope)
    scope.to_s.split(",").map { |s| s.strip.downcase }.reject(&:empty?).uniq.sort.join(",")
  end

  # Upsert from an OmniAuth::AuthHash (or anything that quacks like one).
  #
  # Also banks the access token and the scopes GitHub actually granted with it, which is what makes
  # the app able to ask GitHub anything on this user's behalf. Both halves are recorded in one save
  # so a callback can never leave a row holding a token whose scopes are a previous grant's.
  def self.from_github_omniauth(auth)
    info = auth["info"] || {}

    find_or_initialize_by(github_uid: auth["uid"].to_s).tap do |user|
      user.github_handle = info["nickname"].presence || info["name"].presence || auth["uid"].to_s
      user.email = info["email"]
      user.avatar_url = info["image"]
      user.assign_github_authorization(auth)
      user.save!
    end
  end

  # The token and the scopes it carries, taken off a callback's auth hash.
  #
  # A callback that produced no token leaves the stored one alone rather than clearing it. GitHub
  # omits `credentials` from a mocked or replayed auth hash, and a sign-in that happens to arrive
  # without one is not evidence that the user revoked anything — dropping the token there would
  # silently demote a user who had already granted repository access back to "not connected".
  def assign_github_authorization(auth)
    token = auth.dig("credentials", "token").presence
    return if token.blank?

    self.github_access_token = token
    self.github_token_scopes = self.class.normalize_scopes(auth.dig("extra", "scope"))
    self.github_token_updated_at = Time.current
  end

  # Scopes GitHub reported granting, as a set of strings. Never inferred from what we *asked* for:
  # a user can uncheck an organization on GitHub's consent screen and come back with less than was
  # requested, and treating the request as the grant is exactly how a feature ends up calling an
  # API it has no scope for and rendering a 403 as a bug.
  def github_scopes = github_token_scopes.to_s.split(",").map(&:strip).reject(&:empty?).to_set

  # Whether this user has granted enough for the repository-listing and permission reads that
  # ownership verification rests on. `repo` covers private repositories; `public_repo` is accepted
  # because a user who granted only that can still legitimately register their public ones.
  def github_repository_access? = github_access_token.present? && github_scopes.intersect?(GITHUB_REPOSITORY_SCOPES)

  # Encrypted columns raise when the envelope will not open — which happens for exactly one
  # reason here: the encryption keys changed (see the initializer's note on rotating
  # `secret_key_base`). An unopenable token is operationally identical to no token: the user is
  # asked to authorize again. So it is reported as absent rather than as a 500 on every page that
  # asks whether GitHub is connected.
  def github_access_token
    super
  rescue ActiveRecord::Encryption::Errors::Base
    nil
  end

  def display_name = github_handle

  private

  def normalize_github_handle
    self.github_handle = self.class.normalize_handle(github_handle)
  end
end
