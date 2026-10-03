# frozen_string_literal: true

# WHICH OF A PERSON'S CONNECTED GITHUB ACCOUNTS GITHUB NO LONGER ANSWERS FOR — read for `/account`,
# at most once an hour per person (SPGD-986).
#
# The `GithubInstallation` rows are SpecGuard's own record, and a github.com uninstall has no local
# moment to hook: the row outlives the installation it names until the person next passes through
# the App callback (`GithubInstallationsController#reconcile`). Since SPGD-975 that is not free — a
# person holding a fresh-but-empty `GithubRegistrationGrant` keeps answering a false
# `:not_in_installation` for up to `GithubRegistrationGrant::MAX_AGE` — and the one page that could
# say so, `/account`, listed the dead account identically to a live one. This is the reading that
# lets it name the account instead.
#
# ## The shape, which is the owner's (SPGD-986 decision A)
#
# - CREDENTIAL-GATED. A reading is only attempted with the viewer's own live GitHub token, handed in
#   by the caller. No token (never connected this session, or expired) answers "nothing known", and
#   so does a failed read — the panel then renders exactly as it did before this existed.
# - THROTTLED. The ATTEMPT is throttled, not only the success: a walk of any outcome is recorded,
#   and for `FRESH_FOR` after it no further walk is made. A clean walk's answer is rendered from the
#   cache in that hour; only the first credentialed `/account` render in it pays the page walk, even
#   while GitHub is failing. The lag this accepts is stated, not hidden: an uninstall is named at
#   most about an hour after the first credentialed visit, against the seven days it was invisible
#   for before.
# - FAIL SILENT. A walk that errors makes no claim — and is still throttled. If an earlier clean
#   walk is still held (it is kept for `KEEP_FOR`, longer than it is trusted fresh) its answer is
#   rendered — true as of its walk, and only for the installations it actually covered.
#
# ## What it deliberately is not
#
# - NOT a capture site. It calls `InstallationRepositories.sources` directly and never goes through
#   `GithubRepositoryListing`, whose `github_sources` is the sole `GithubRegistrationGrant.capture`
#   (see `AccountsController#show`). A read of the connected-accounts list must not mint a grant.
# - NOT a destroy. It reports; the person presses the existing per-row Disconnect, which carries the
#   mirrored grant invariant (`forget_registration_grant_if_last_installation`). A read must not
#   destroy.
# - NOT shared infrastructure. The hour is this panel's walk throttle, not a general GitHub cache.
#
# ## The store
#
# `Rails.cache`, because what is held is reproducible by asking GitHub again — losing it, or a
# deployment whose store is per-process, costs one more walk and never a wrong answer. (Contrast
# `PendingBulkSelection`, which rejects `Rails.cache` because losing ITS data loses a person's
# work.) Only installation ids and statuses are stored: no token, no repository name.
class InstallationReachability
  FRESH_FOR = 1.hour
  KEEP_FOR = 1.day

  # `statuses` and `walked_at` are the last CLEAN walk's (nil / empty before there was one);
  # `attempted_at` is the last walk of ANY outcome. The throttle runs on the attempt, the answer on
  # the clean walk.
  Entry = Data.define(:attempted_at, :walked_at, :statuses)

  class << self
    # The ids, among `installations`, that GitHub answered 404 for — an empty set whenever no
    # reading is held or obtainable. Never raises.
    def unreachable_ids(user, installations:, user_token:)
      return Set.new if user_token.blank? || installations.empty?

      ids = installations.map(&:installation_id)
      entry = load(user)
      return unreachable_in(entry, ids) if throttled?(entry, ids)

      walked = walk(user, user_token, entry)
      unreachable_in(walked, ids)
    end

    # Dropped when the person passes back through the App callback: an account they have just
    # reconnected must not keep being named as gone from a reading taken before they did.
    def forget(user)
      Rails.cache.delete(key(user))
    end

    private

    # Within the hour of an attempt, no walk is made — whether or not that attempt was clean. A
    # failing GitHub (outage, rate limit, a revoked token, one persistently erroring installation)
    # must not turn every `/account` render into the per-render walk this throttle exists to refuse.
    # The one exception is a clean reading that does not know a row the person now holds: a failed
    # attempt claims nothing about any row, so only a clean entry can be "missing" one.
    def throttled?(entry, ids)
      return false unless entry && entry.attempted_at > FRESH_FOR.ago
      return true unless entry.walked_at && entry.walked_at == entry.attempted_at

      covers?(entry, ids)
    end

    # Always records the attempt. Returns the entry to answer from: the new clean one, else the
    # earlier clean one (kept, for the rows it knew), else nil.
    def walk(user, user_token, previous)
      statuses = read_statuses(user, user_token)
      now = Time.current
      entry =
        if statuses
          Entry.new(attempted_at: now, walked_at: now, statuses: statuses)
        else
          kept = previous if previous&.walked_at && previous.walked_at > KEEP_FOR.ago
          Entry.new(attempted_at: now, walked_at: kept&.walked_at, statuses: kept&.statuses || {})
        end
      store(user, entry)
      entry
    end

    # `nil` whenever the walk made no claim.
    def read_statuses(user, user_token)
      sources = InstallationRepositories.sources(user, user_token: user_token)
      # `error` is the first failure of ANY installation; a 404 is not one (`Outcome#unreadable?`),
      # so a clean walk may still contain dead accounts. Anything less than clean makes no claim.
      return nil unless sources.installed? && sources.error.nil? && sources.outcomes.any?

      statuses = sources.outcomes.to_h { |outcome| [outcome.installation_id, outcome.status] }
      statuses.key?(nil) ? nil : statuses
    rescue GithubApi::Error => e
      Rails.logger.warn("[InstallationReachability] #{e.class}: #{e.message}")
      nil
    end

    def unreachable_in(entry, ids)
      return Set.new if entry.nil?

      ids.select { |id| entry.statuses[id] == :unreadable }.to_set
    end

    def covers?(entry, ids) = ids.all? { |id| entry.statuses.key?(id) }

    def key(user) = "installation_reachability/user/#{user.id}"

    def store(user, entry)
      payload = { "attempted_at" => entry.attempted_at.to_i,
                  "walked_at" => entry.walked_at&.to_i,
                  "statuses" => entry.statuses.transform_keys(&:to_s).transform_values(&:to_s) }
      Rails.cache.write(key(user), payload, expires_in: KEEP_FOR)
    end

    def load(user)
      payload = Rails.cache.read(key(user))
      return nil unless payload.is_a?(Hash) && payload["statuses"].is_a?(Hash) && payload["attempted_at"]

      walked = payload["walked_at"]
      Entry.new(attempted_at: Time.zone.at(payload["attempted_at"].to_i),
                walked_at: walked && Time.zone.at(walked.to_i),
                statuses: payload["statuses"].to_h { |id, status| [id.to_i, status.to_sym] })
    end
  end
end
