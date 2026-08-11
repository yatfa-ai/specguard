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

  # The five-way answer from `User.resolve_by_handle`. A handle is deliberately not unique across
  # rows, so a caller that gets a bare `User` back cannot tell "this is the person you named" from
  # "this is one of several people who might be". This makes the difference impossible to ignore.
  #
  # `:malformed` is separate from `:not_found` for the same reason: "that is not a GitHub handle"
  # and "nobody has signed in with that handle" are different facts about the world and want
  # different answers from a caller. Collapsing them would tell an owner who pasted a profile URL
  # to go ask a colleague to re-authenticate — advice that sends them to fix the wrong thing.
  #
  # `:archived` is separate from `:not_found` by that same argument, and it is the sharper case:
  # folding it in would tell an owner "nobody has signed in as X yet — ask them to sign in once",
  # which is both false and impossible to act on, since an archived person is refused at sign-in
  # by design. It sends the owner to badger a colleague who cannot comply.
  Resolution = Data.define(:status, :user, :match_count) do
    def found? = status == :found
    def not_found? = status == :not_found
    def ambiguous? = status == :ambiguous
    def malformed? = status == :malformed
    def archived? = status == :archived
  end

  has_many :repositories, dependent: :destroy
  # Both sides of the membership declare `dependent: :destroy`; dropping either one leaves the
  # foreign key to fail on destroy.
  has_many :repository_memberships, dependent: :destroy
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
  # which is this user's own access and does go away with them.
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

  # Archiving is an offboarding control, not a deletion: it refuses sign-in (SessionsController),
  # stops an already-live session from authenticating (ApplicationController#current_user) and takes
  # the person out of the invitable set (`resolve_by_handle`). It destroys and nullifies NOTHING —
  # their repositories, test runs, spec intents, minted API keys and the memberships they granted
  # all stay, attribution intact, which is the entire reason to archive rather than destroy.
  #
  # DELIBERATELY NOT A `default_scope`. A blanket scope would silently rewrite every read in the
  # app: the members list joins `users` and orders over it (MembershipsController#index), and every
  # association traversal — `membership.user`, `api_key.created_by_user`, `membership.granted_by_user`
  # — would start returning nil for an archived person. That would quietly *un-attribute* the very
  # history this state exists to preserve, and it would do it in the rendering layer where nobody
  # would read it as a policy decision. Read sites opt in one at a time, on purpose, and each one
  # is a line somebody had to write.
  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  def archived? = archived_at.present?
  def active? = !archived?

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

    # One query for both halves, partitioned here rather than two round trips — and archived rows
    # are read rather than filtered in SQL because their absence is itself an answer (`:archived`)
    # and a `WHERE archived_at IS NULL` would throw away the fact that the handle matched anybody.
    active_matches, archived_matches = where(github_handle: normalized).order(:id).partition(&:active?)

    # ARCHIVED ROWS ARE NOT PART OF THE INVITABLE SET, and that ordering is the whole rule:
    #
    #   - Ambiguity is only ever reported among rows that could actually be granted access. One
    #     active + one archived row sharing a recycled handle now resolves `:found` on the active
    #     one, where it used to be `:ambiguous` — an owner is no longer blocked from inviting a
    #     real colleague by a departed one holding the same string. Two active + one archived is
    #     still `:ambiguous`, and reports 2, the number of people it will not choose between.
    #   - `:archived` is reported only when there is nothing invitable at all, and it is reported
    #     however many archived rows there are: to the caller, "everyone with that handle is
    #     archived" is one fact and one sentence, and there is no choice left to be ambiguous about.
    #   - `user` stays nil, as it does for every non-`found` status. An archived row is precisely
    #     the row a caller must not act on, so handing it back would invite exactly that.
    case active_matches.length
    when 0
      if archived_matches.any?
        Resolution.new(status: :archived, user: nil, match_count: archived_matches.length)
      else
        Resolution.new(status: :not_found, user: nil, match_count: 0)
      end
    when 1 then Resolution.new(status: :found, user: active_matches.first, match_count: 1)
    else Resolution.new(status: :ambiguous, user: nil, match_count: active_matches.length)
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
  #
  # A PURE IDENTITY UPSERT, AND IT STAYS ONE: it resolves who the callback is, it does not decide
  # whether they may be let in. `archived_at` is neither read nor written here — refusing an
  # archived person is `SessionsController`'s job, because that is where a session would be
  # established and where the refusal has somewhere to redirect to. The known consequence is that
  # an archived person's row is still refreshed (handle, avatar, email, token) on every refused
  # attempt. That is intentional, not a leak of the archive: the row was already theirs, the
  # refresh grants nothing, and `archived_at` itself is never cleared — so an archived person
  # cannot undo their own archiving by visiting the callback URL.
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
