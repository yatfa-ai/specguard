# frozen_string_literal: true

# GITHUB'S ANSWER TO "WHICH REPOSITORIES MAY THIS PERSON REGISTER?", SNAPSHOTTED WHILE A BROWSER
# SESSION STILL HELD THE TOKEN THAT COULD ASK.
#
# `InstallationRepositories` asks GitHub with the USER's own short-lived token, and that token lives
# in the session and nowhere else — deliberately, see `GithubUserSession`. So the machine surface
# has a problem the web surface does not: a request authenticated by an `sgu_` API key has a person,
# has their installations, and has no credential to ask GitHub about them with. It cannot ask, and
# it must not be allowed to skip asking.
#
# This is the third option: don't ask at request time, and don't persist a credential either.
# Persist WHAT GITHUB SAID, taken at a moment a live token was in hand, and redeem it later.
#
# ## What that costs, stated plainly
#
# A live check is authoritative at the instant of the write. A snapshot is authoritative at the
# instant it was TAKEN, which means it can fail open: somebody who has lost admin on a repository
# still holds a grant that says otherwise. Two things bound that, and both are in this class:
#
#   * `MAX_AGE` — a grant past it redeems nothing, with its own refusal naming the fix.
#   * The refresh point costs nothing, so an active person's grant is never old. It is taken from
#     `GithubRepositoryListing#github_sources` — a read that ALREADY happens, memoized and lazy, on
#     the pages that list repositories — so no GitHub round trip is added anywhere and the bound
#     only ever bites on an account nobody has signed into for a week.
#
# ## Absence is a refusal, so an incomplete reading is not a grant
#
# `Sources#complete?` is the load-bearing precondition of `capture`. In a grant, a name that is not
# in the set is refused — that is the whole mechanism. So a set built from a reading that was cut
# short (our own page walk hit `MAX_PAGES`, or one of the person's installations would not answer)
# would silently refuse repositories they genuinely administer, and would do it in a way nothing
# distinguishes from GitHub having said no. `InstallationRepositories#name_verdict` states the same
# rule for the live path. Here the consequence is stronger, because the snapshot outlives the
# request that took it: a partial reading is DISCARDED, and the previous grant — with its previous
# `captured_at` — survives untouched.
class GithubRegistrationGrant < ApplicationRecord
  # How long a snapshot may be redeemed for.
  #
  # Seven days is a bound on how long somebody who has LOST GitHub admin can still register with a
  # grant that predates the loss. Short enough that a revoked administrator does not linger for a
  # quarter; long enough that an agent running weekly against a person who signs in occasionally
  # never sees the refusal at all. It is a product decision rather than a security boundary — the
  # security boundary is that a name outside the grant is refused at any age.
  MAX_AGE = 7.days

  belongs_to :user

  validates :captured_at, presence: true
  validates :user_id, uniqueness: true

  # Take (or replace) this person's grant from a reading of their installations.
  #
  # Returns the grant, or `nil` when the reading was not one a grant may be built from. Never
  # raises: every caller is a page render that has already got what it came for, and a grant is a
  # side effect of that read rather than its purpose.
  #
  # ## Why the whole row is replaced
  #
  # A grant is a statement of what GitHub says NOW, in full. Merging a new reading into an old one
  # would keep names the person has since lost admin on — precisely the state the ownership gate
  # exists to refuse — and the older the row got the more of them it would carry. So both arrays and
  # the stamp are overwritten together, and a name absent from the new reading is gone.
  def self.capture(user:, sources:)
    return nil if user.nil? || sources.nil?
    # An incomplete reading is our ignorance, not GitHub's answer. See the class comment: writing it
    # would convert a truncated page walk into a refusal of repositories this person administers.
    return nil unless sources.complete?

    grant = find_or_initialize_by(user_id: user.id)
    grant.registrable_full_names = downcased(sources.registrable)
    grant.visible_full_names = downcased(sources.repos)
    grant.captured_at = Time.current
    grant.save!
    grant
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Two concurrent page renders for the same person race on the unique index. Both were writing
    # the same GitHub answer, so the loser has nothing to add and nothing to report.
    find_by(user_id: user.id)
  end

  def self.downcased(repos)
    repos.map { |repo| repo.full_name.to_s.downcase }.uniq
  end
  private_class_method :downcased

  # Past the bound, and therefore redeeming nothing. `captured_at` is never nil on a persisted row
  # (`NOT NULL`, and validated), but an unsaved one is treated as stale rather than as fresh — the
  # safe reading of "I cannot tell how old this is" is "too old".
  def stale?(now: Time.current)
    return true if captured_at.nil?

    captured_at < now - MAX_AGE
  end

  # Does GitHub's snapshot say this person ADMINISTERS this repository? The only question that
  # permits a registration.
  def registrable?(full_name)
    registrable_full_names.include?(normalize(full_name))
  end

  # Could this person SEE it at all? Permits nothing — it only decides which refusal is true.
  def visible?(full_name)
    visible_full_names.include?(normalize(full_name))
  end

  private

  # Case-insensitively, for the reason `InstallationRepositories.verify_batch` gives: GitHub logins
  # and repository names are, and `Repository#normalize_full_name` has already run on the value
  # being asked about.
  def normalize(full_name) = full_name.to_s.strip.downcase
end
