# frozen_string_literal: true

# "May this user register this repository?", answered by GitHub rather than by whoever typed the
# slug.
#
#   GithubOwnership.verify(user: current_user, full_name: "acme/billing-service")
#   # => GithubOwnership::Verdict
#
# Before this existed, `RepositoriesController#create` performed no ownership check at all: any
# signed-in user could claim any `org/repo` that was not already taken and become its owner in
# SpecGuard. `github_full_name` is both the display identity and the globally unique key, so a
# claimed slug also locked the real owner out of registering it.
#
# ## Why `permissions.admin` and not repository existence
#
# That a token can *see* a repository says only that it is public, or that the user has some read
# access to it — neither of which is ownership. GitHub reports the caller's own permission level on
# every authenticated repository read, and `admin` is the level that can manage the repository's
# settings, keys and webhooks. That is the honest analogue of "may register it here", and it
# deliberately admits an org repository the user administers without owning personally, which a
# handle-vs-org-segment string comparison would have refused.
#
# ## Why a Verdict rather than a boolean
#
# Eight different things can stop a registration and most of them are the user's to fix, each in a
# different way: authorize the app, re-authorize a revoked token, widen a too-narrow grant, get an
# organization to approve SpecGuard, pick a repository you actually administer, check the spelling,
# wait out a rate limit. A boolean collapses all of them into "no", which is how a UI ends up
# telling someone to fix the wrong thing — or, worse, telling someone whose organization enforces
# SSO to "try again shortly" for a condition that will never clear until a human clicks approve.
# Every non-verified status carries the sentence the form should show, and `reauthorize?` marks the
# ones the user resolves by granting access rather than by editing the field.
class GithubOwnership
  # `:verified`   GitHub reports this user as an admin of this repository. The only pass.
  # `:not_connected`  no usable token, or one whose granted scopes cannot read repositories.
  # `:token_rejected` GitHub rejected the token — revoked on GitHub's side, or expired.
  # `:not_admin`      the repository is visible to this user, who is not an admin of it. This is
  #                   the squatting case, and the one the gap was.
  # `:not_found`      invisible to this token. NOT "does not exist" — GitHub answers 404 for a
  #                   private repository the caller cannot read, so the message must cover both.
  # `:sso_required`   GitHub *refused*, because the organization enforces SAML SSO and this token
  #                   is not authorized for it. Distinct from `:unavailable` on purpose: it does
  #                   not clear by waiting, and telling this user to "try again shortly" is telling
  #                   them to retry forever. Org-owned repositories behind SSO are the mainline
  #                   case for a CI product, not a corner.
  # `:scope_too_narrow` GitHub refused because the grant cannot answer the question. A re-authorize
  #                   fixes it, so it is a `reauthorize?` status.
  # `:rate_limited`   GitHub refused because the token's hourly budget is spent. The one 403 that
  #                   genuinely is "try again shortly", and it says so with the reason named.
  # `:unavailable`    GitHub could not be reached or would not answer. Explicitly not a pass:
  #                   an outage must fail closed, or the gap reopens on every 500.
  Verdict = Data.define(:status, :full_name, :message) do
    def verified? = status == :verified

    # The three the user fixes by granting access, not by changing what they typed — so the form can
    # offer the authorize button instead of an error the field cannot resolve.
    def reauthorize? = %i[not_connected token_rejected scope_too_narrow].include?(status)
  end

  MESSAGES = {
    not_connected: "could not be verified — connect your GitHub repositories first.",
    token_rejected: "could not be verified — your GitHub authorization is no longer valid. " \
                    "Reconnect and try again.",
    not_admin: "is not a repository you administer on GitHub. Only an admin of a repository " \
               "can register it here.",
    not_found: "was not found on GitHub, or is not visible to your GitHub account.",
    sso_required: "could not be verified — GitHub refused the request. If this repository " \
                  "belongs to an organization, that organization may need to approve SpecGuard, " \
                  "and your GitHub authorization may need to be approved for it in the " \
                  "organization's settings.",
    scope_too_narrow: "could not be verified — your GitHub authorization does not cover " \
                      "repository access. Reconnect to grant it.",
    rate_limited: "could not be verified — GitHub's rate limit for your account has been " \
                  "reached. Try again in a few minutes.",
    unavailable: "could not be verified — GitHub did not answer. Try again shortly."
  }.freeze

  # Which verdict each 403 becomes. GitHub answers 403 for three unrelated reasons and only one of
  # them is waitable; see `GithubApi::Forbidden`.
  FORBIDDEN_VERDICTS = {
    rate_limited: :rate_limited,
    sso_required: :sso_required,
    insufficient_scope: :scope_too_narrow
  }.freeze

  class << self
    def verify(user:, full_name:)
      full_name = full_name.to_s.strip

      # Asked of the stored grant, before any network call: a user who never authorized repository
      # access has nothing to ask GitHub *with*, and the answer is "authorize", not "denied".
      return verdict(:not_connected, full_name) unless user&.github_repository_access?

      client = GithubApi.for(user)
      return verdict(:not_connected, full_name) if client.nil?

      decide(client.repository(full_name), full_name)
    rescue GithubApi::Error => e
      verdict(status_for(e, full_name), full_name)
    end

    # The same question asked of many repositories at once, for bulk registration — one `Verdict`
    # per name, in the order given.
    #
    # ## Why this is not `full_names.map { verify(...) }`
    #
    # That is one GitHub round trip per repository. At the twenty-repository batch SPGD-355 is
    # written for it is twenty sequential calls before the first row is saved, and it grows without
    # a bound the user can see: a hundred-repository organization is a hundred, which is a request
    # that times out rather than a batch that is slow. So the listing — ONE call, the same one the
    # picker was rendered from — is the source, and `permissions.admin` on each row is the same
    # field `verify` reads off `GET /repos/:owner/:repo`. It is GitHub's answer to the same
    # question, and it is not a weaker one for having arrived in a list.
    #
    # This is re-asked at submit time and never trusted from the browser. The form's checkboxes are
    # client-controlled, so a submitted name that GitHub does not report as administered is refused
    # here whatever the page offered — which is the whole reason a bulk path may reuse the listing
    # without reopening the gap SPGD-354 closed.
    #
    # ## The truncation fallback
    #
    # `MAX_PAGES` bounds the listing, so a name can be absent from it for two very different
    # reasons. When the listing is COMPLETE, absent means GitHub does not report this repository to
    # this token at all, which is exactly `:not_found`. When it is TRUNCATED, absent means only that
    # we stopped reading — so the name is asked about individually rather than refused for a
    # property of our own page walk. That fallback is per name and unbounded in principle, which is
    # why `BulkRegistration::MAX_BATCH` bounds the input: the cap on the batch is what keeps the cap
    # on the listing from turning into an unbounded fan-out.
    #
    # ## Failure is whole-batch and closed
    #
    # A listing call that raises gives EVERY name the verdict that error maps to, exactly as
    # `verify` would have given it one at a time. Nothing is registered on a GitHub outage, for the
    # reason `RepositoriesController#save_with_verified_ownership` states: verifying by default
    # during an outage reopens the gap intermittently, which is worse than the gap itself.
    def verify_batch(user:, full_names:)
      names = Array(full_names).map { |name| name.to_s.strip }.reject(&:empty?)
      return [] if names.empty?

      return names.map { |name| verdict(:not_connected, name) } unless user&.github_repository_access?

      client = GithubApi.for(user)
      return names.map { |name| verdict(:not_connected, name) } if client.nil?

      listing = client.repositories
      # Keyed case-insensitively because GitHub logins and repository names are, and a name may
      # arrive here having been round-tripped through a form.
      index = listing.repos.index_by { |repo| repo.full_name.downcase }

      names.map { |name| batch_verdict(user, name, index, listing.truncated?) }
    rescue GithubApi::Error => e
      status = status_for(e, "#{names.length} repositories")
      names.map { |name| verdict(status, name) }
    end

    private

    def batch_verdict(user, name, index, truncated)
      repo = index[name.downcase]
      return decide(repo, name) if repo

      # Absent from a complete listing is GitHub's own answer; absent from a truncated one is our
      # page walk's, and those must not read the same.
      truncated ? verify(user: user, full_name: name) : verdict(:not_found, name)
    end

    def decide(repo, full_name)
      repo.admin? ? verdict(:verified, full_name) : verdict(:not_admin, full_name)
    end

    # Which verdict a GitHub failure becomes, and what gets logged on the way.
    #
    # `Unauthorized` and `NotFound` are not logged: both are ordinary answers about the world (a
    # revoked token, a repository this account cannot see) and neither carries anything the log does
    # not already have. The other two do carry something — GitHub's own sentence, which can name an
    # organization and is not the browser's business.
    def status_for(error, subject)
      case error
      when GithubApi::Unauthorized then :token_rejected
      when GithubApi::NotFound then :not_found
      when GithubApi::Forbidden
        # Logged *and* differentiated. The verdict carries the reason, because "wait" and "get your
        # org to approve this" are opposite instructions and a user given the wrong one is stuck for
        # good.
        Rails.logger.warn("[GithubOwnership] #{subject}: #{error.class}(#{error.reason}): #{error.message}")
        FORBIDDEN_VERDICTS.fetch(error.reason, :scope_too_narrow)
      else
        Rails.logger.warn("[GithubOwnership] #{subject}: #{error.class}: #{error.message}")
        :unavailable
      end
    end

    def verdict(status, full_name)
      Verdict.new(status: status, full_name: full_name, message: MESSAGES[status])
    end
  end
end
