# frozen_string_literal: true

require "openssl"

# THE AGENT CREDENTIAL — a machine key that speaks for NOBODY: neither one repository (`sgk_`) nor
# one person (`sgu_`), but an explicit SET of repositories under a permission set, both fixed at
# mint time. It answers the question neither sibling can: "how does an automated agent read N
# repositories without holding a person's rights?" — `sgk_` is one repository by design, and `sgu_`
# speaks with the person's full grantable surface, which is over-privilege for an agent.
#
# The two boundaries are stored, not derived:
#
#   * `repository_ids` is the READ boundary. The key may name exactly these repositories and
#     nothing outside the set — a repository outside it is a 404 indistinguishable from a
#     nonexistent one, on the same nil-is-404 fork every scoped read takes.
#   * `permissions` is the VERB boundary, drawn from `RepositoryMembership::PERMISSIONS` verbatim —
#     the same four strings a membership stores, so one vocabulary serves both kinds of grant.
#
# ## The prefix is load-bearing, not decoration
#
# `sga_` completes the prefix discipline `UserApiKey::TOKEN_PREFIX` documents: all three prefixes
# are the same LENGTH and no one of them is a prefix of another, so
# `Api::BaseController#authenticate_api_key!` still decides WHICH table from the token's first four
# characters, before any table is read, and resolution stays the single indexed read it has always
# been. The seam spec walks the credential classes and asserts that discipline, so a fourth prefix
# that breaks it fails there rather than in production.
#
# ## What the grant is measured against at mint time
#
# A person mints the key from THEIR rights, and the validations below are
# `RepositoryMembership#grantor_holds_every_granted_permission` with the minting person in the
# grantor's seat: every repository in the set must be one the owner can open, and on each one the
# permission set must be within what `RepositoryPolicy#grantable_permissions` says they may hand
# out. The bound is read from the PERSISTED membership, so a grant cannot bootstrap itself — the
# same rule a membership grant answers to.
#
# The bound is a MINT-TIME fact. Nothing re-derives it per request: narrowing the owner's own
# membership afterwards does not narrow a key they already minted (revoking the key is the lever
# for that, and it is deliberately owner-facing in `/account`). Two things DO reach past mint time,
# both at the resolution site: `revoke!` retires the key, and an ARCHIVED owner's key resolves to
# nothing — see `authenticate`, which carries the same offboarding cut `UserApiKey.authenticate`
# does, because a key whose rights were fixed by somebody the offboarding control has already
# refused is that control's exact blind spot.
#
# ## There is no `regenerate!`, deliberately
#
# For the same reason `UserApiKey` states: a lost agent token is recovered by minting another and
# revoking this one — two rows and an audit trail, rather than one row whose history quietly
# changes meaning. An agent key is also the one credential whose grants are CONFIGURABLE at mint
# time, so "change what it can reach" has an honest answer that is not rotation: mint the narrower
# key, revoke the wider one, and the trail says which was retired when.
class AgentApiKey < ApplicationRecord
  # Same-length discipline as both siblings — see the class header. Four characters, `sg`,
  # one distinguishing letter, one underscore: no prefix of one is a prefix of another.
  TOKEN_PREFIX = "sga_"
  TOKEN_BYTES = 24

  belongs_to :user

  # Populated by the request that minted this row, and `nil` on every record loaded from the
  # database — the same shape as both siblings' `raw_token`, for the same reason.
  attr_reader :raw_token

  before_validation :assign_token, on: :create
  before_validation :normalize_grants

  validates :token_digest, presence: true, uniqueness: true
  validates :name, presence: true

  validate :permissions_are_known
  validate :repositories_are_present
  validate :repositories_are_reachable_by_the_owner
  validate :owner_holds_every_granted_permission

  # The retirement split, named once, on `ApiKey`'s rule: NO `default_scope` — each reader picks a
  # side and says so. `revoked_at` is written by `revoke!` and never cleared.
  scope :live, -> { where(revoked_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  # Resolve a Bearer token to its key — `live` only, and only while the OWNER is still active.
  #
  # The `live` filter is the security half of retirement, exactly as `ApiKey.authenticate` states
  # it: `revoke!` keeps the row so a revoked token stays attributable, which means the row would
  # otherwise keep resolving.
  #
  # `eager_load(:user).merge(User.active)` is `UserApiKey.authenticate`'s spelling, carried here
  # for its offboarding cut: archiving the owner takes the key with them, at the resolution site,
  # so the endpoint answers 401 with no more detail than it gives a token that never existed. The
  # join is paid for either way to apply the scope; `eager_load` rather than `joins` is what keeps
  # the claim "resolution is one indexed read" true while paying it. Still ONE statement against
  # this table, on the unique digest index.
  def self.authenticate(token)
    return nil if token.blank?

    live.eager_load(:user).merge(User.active).find_by(token_digest: digest(token))
  end

  # THE READ BOUNDARY, as a relation. This is what "the key's repository set" resolves to — the
  # plural endpoints scope their reads through here, so a repository outside the set never enters
  # a query, let alone a response. Deleted repositories drop out on their own (the id matches no
  # row), which is the honest answer: the grant named a repository that no longer exists.
  def repositories
    Repository.where(id: repository_ids)
  end

  # Whether THIS key's boundary covers one repository — the `member?` half of the policy protocol
  # `AgentApiKeyPolicy` answers on the key's behalf. An in-memory array read, no query.
  def covers?(repository)
    repository.present? && repository_ids.include?(repository.id)
  end

  # Whether the key's permission set holds one stored permission string — the verb half of the
  # same protocol. `view` is deliberately NOT special-cased here: the policy owns the rule that
  # set membership implies read, exactly as `RepositoryPolicy` owns the rule that membership
  # implies it.
  def grants?(permission)
    permissions.include?(permission)
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  # Retire this key: the token stops authenticating, and the ROW STAYS — the retirement pattern
  # `ApiKey#revoke!` established and its comment argues for (a hard delete made a revoked token's
  # 401 unreportable; keeping the row keeps the artifact the failure path needs). `update_column`
  # rather than `save!` for the same reason: a stamp on existing state, not a validation event.
  # Idempotent — a replayed revoke re-stamps, which is unobservable, because the button is offered
  # only on live keys.
  def revoke!
    update_column(:revoked_at, Time.current)
    self
  end

  def revoked?
    revoked_at.present?
  end

  # Safe to show anywhere: identifies the key without revealing it. Same construction as both
  # siblings, carrying THIS class's prefix so a person holding all three kinds can tell which
  # list they are looking at.
  def token_hint
    "#{TOKEN_PREFIX}…#{token_digest.last(6)}"
  end

  private

  # Array columns collect whitespace, blanks and duplicates the moment a form writes to them —
  # the same normalization `RepositoryMembership` runs on its permissions column, extended to the
  # repository set this model adds. Integer coercion here rather than at the controller: a grant
  # is a set of ids wherever it arrives from.
  def normalize_grants
    self.repository_ids = Array(repository_ids).filter_map { |id| Integer(id) rescue nil }.uniq
    self.permissions = Array(permissions).map { |permission| permission.to_s.strip }.reject(&:empty?).uniq
  end

  def permissions_are_known
    unknown = permissions - RepositoryMembership::PERMISSIONS
    return if unknown.empty?

    errors.add(:permissions, "contains unknown #{'value'.pluralize(unknown.size)}: #{unknown.join(', ')}")
  end

  # A credential that can reach nothing is not a grant, it is a typo that authenticates — the
  # mint form cannot tick zero repositories by accident, so an empty set here means a caller
  # bypassing the form. An EMPTY PERMISSION set, by contrast, is deliberate and valid below.
  def repositories_are_present
    errors.add(:repository_ids, "must name at least one repository") if repository_ids.empty?
  end

  # A grant may only name repositories the OWNER can open — `Repository.accessible_by` is this
  # application's read-side boundary, and a key minted over a repository its own minter cannot see
  # would be an escalation channel: name an id blind, hold a credential to it.
  #
  # One scoped query answers for the whole set; only a FAILURE pays a second (to name the refused
  # repositories in the sentence), because a sentence that says "you cannot open that" without
  # saying WHICH checkbox to untick sends the reader down the list by hand.
  def repositories_are_reachable_by_the_owner
    return if repository_ids.empty? || user.nil?

    reachable_ids = Repository.accessible_by(user).where(id: repository_ids).pluck(:id)
    unreachable_ids = repository_ids - reachable_ids
    return if unreachable_ids.empty?

    names = Repository.where(id: unreachable_ids).order(:github_full_name).pluck(:github_full_name)
    errors.add(:repository_ids, "names repositories you cannot open: #{names.join(', ')}")
  end

  # Nobody may grant access they do not themselves hold — `RepositoryMembership#grantor_holds_
  # every_granted_permission` with the minting person in the grantor's seat, because that is
  # exactly what minting an agent key is: handing a set of grants to a machine. The bound comes
  # from `RepositoryPolicy#grantable_permissions` rather than being re-derived here, so "what a
  # grant may contain" stays one rule across memberships and agent keys.
  #
  # Unlike the membership version this one names the REPOSITORY in its sentence: a key covers a
  # set, and "you do not hold repo.delete" is unactionable when the owner holds it on three of the
  # four repositories they picked. The error message is the reader's way back to the checkbox.
  #
  # An empty permission set passes: the repository set alone is the read boundary, and a key that
  # may list and open its repositories but gate no further verb is a coherent, minimal grant.
  def owner_holds_every_granted_permission
    return if permissions.empty? || user.nil?

    over_reach = repositories.filter_map do |repository|
      ungrantable = permissions - RepositoryPolicy.new(user, repository).grantable_permissions
      next if ungrantable.empty?

      "#{ungrantable.join(', ')} on #{repository.github_full_name}"
    end

    return if over_reach.empty?

    errors.add(:permissions, "include permissions you do not hold: #{over_reach.join('; ')}")
  end

  # `||=` for the reason both siblings give: a `valid?` before the `save` runs the callback twice,
  # and without it the second run would swap in a different token under anyone who had already
  # read `raw_token`. There is no `regenerate!` to defeat the idempotence.
  def assign_token
    @raw_token ||= "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(TOKEN_BYTES)}"
    self.token_digest = self.class.digest(@raw_token)
  end
end
