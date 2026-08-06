# frozen_string_literal: true

# A human, identified by their GitHub OAuth identity. `github_uid` is the stable key — a user may
# rename their GitHub handle and must still resolve to the same row.
class User < ApplicationRecord
  # A GitHub login, as GitHub itself constrains it: alphanumerics and single hyphens, no leading or
  # trailing hyphen, 39 characters at most. Applied to the *query* in `resolve_by_handle`, never as
  # a validation — see the comment there.
  HANDLE_FORMAT = /\A[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?\z/

  # The three-way answer from `User.resolve_by_handle`. A handle is deliberately not unique across
  # rows, so a caller that gets a bare `User` back cannot tell "this is the person you named" from
  # "this is one of several people who might be". This makes the difference impossible to ignore.
  Resolution = Data.define(:status, :user, :match_count) do
    def found? = status == :found
    def not_found? = status == :not_found
    def ambiguous? = status == :ambiguous
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

    # A string GitHub could not have issued as a login cannot be anyone's handle. This is also what
    # keeps a fallback-derived handle (`from_github_omniauth` may store a display name such as
    # "The Octocat") from being resolvable as an identity.
    return Resolution.new(status: :not_found, user: nil, match_count: 0) unless normalized&.match?(HANDLE_FORMAT)

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

  # Upsert from an OmniAuth::AuthHash (or anything that quacks like one).
  def self.from_github_omniauth(auth)
    info = auth["info"] || {}

    find_or_initialize_by(github_uid: auth["uid"].to_s).tap do |user|
      user.github_handle = info["nickname"].presence || info["name"].presence || auth["uid"].to_s
      user.email = info["email"]
      user.avatar_url = info["image"]
      user.save!
    end
  end

  def display_name = github_handle

  private

  def normalize_github_handle
    self.github_handle = self.class.normalize_handle(github_handle)
  end
end
