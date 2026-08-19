# frozen_string_literal: true

# A human, identified by their GitHub OAuth identity. `github_uid` is the stable key — a user may
# rename their GitHub handle and must still resolve to the same row.
class User < ApplicationRecord
  # A GitHub login, as GitHub itself constrains it: alphanumerics and single hyphens, no leading or
  # trailing hyphen, 39 characters at most. Applied to the *query* in `resolve_by_handle`, never as
  # a validation — see the comment there.
  HANDLE_FORMAT = /\A[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?\z/

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

  # The GitHub App installations this user reached SpecGuard through — where there is something for
  # them to read, not yet a claim to any of it. What they may register is settled by reading those
  # installations with this user's OWN credential and requiring GitHub to name them an
  # administrator (`InstallationRepositories`).
  #
  # `:destroy`, unlike the two associations above, and the asymmetry is the same argument they
  # make: a `GithubInstallation` row is nobody else's data. It holds one public numeric id and no
  # credential — the token SpecGuard reads GitHub with is the viewer's own, and lives in their
  # session (`GithubUserSession`) — so destroying it takes nothing away from a colleague and leaves
  # no orphan. It also cannot keep a user undestroyable for a reason they cannot see: connecting
  # GitHub is not the sort of act that should quietly become irreversible.
  has_many :github_installations, dependent: :destroy

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

  # Upsert from an OmniAuth::AuthHash (or anything that quacks like one).
  #
  # Identity and nothing else. The callback's `credentials` are deliberately dropped on the floor:
  # sign-in asks GitHub for a handle, an avatar and an email address, and the token that comes back
  # with them is of no use to an app whose repository access is a GitHub App installation
  # (`GithubInstallation`). Keeping it would be keeping a credential for the sake of it.
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
      user.save!
    end
  end

  # Whether this user has connected any repositories at all — asked before any network call, so a
  # page that only needs to know "is there anything to show" does not pay a GitHub round trip to
  # find out there is not.
  #
  # This is deliberately NOT an authorization check. It says a user reached SpecGuard through an
  # installation at some point, which is a fact about our own table; what may actually be
  # registered is decided by reading that installation live (`InstallationRepositories`), because
  # nothing here is kept in step with GitHub and a row can outlive the installation it names.
  def github_installed? = github_installations.any?

  def display_name = github_handle

  private

  def normalize_github_handle
    self.github_handle = self.class.normalize_handle(github_handle)
  end
end
