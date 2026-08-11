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

      repo = client.repository(full_name)
      repo.admin? ? verdict(:verified, full_name) : verdict(:not_admin, full_name)
    rescue GithubApi::Unauthorized
      verdict(:token_rejected, full_name)
    rescue GithubApi::NotFound
      verdict(:not_found, full_name)
    rescue GithubApi::Forbidden => e
      # Logged *and* differentiated. The log keeps GitHub's own sentence, which can name an
      # organization and is not the browser's business; the verdict carries the reason, because
      # "wait" and "get your org to approve this" are opposite instructions and a user given the
      # wrong one is stuck for good.
      Rails.logger.warn("[GithubOwnership] #{full_name}: #{e.class}(#{e.reason}): #{e.message}")
      verdict(FORBIDDEN_VERDICTS.fetch(e.reason, :scope_too_narrow), full_name)
    rescue GithubApi::Unavailable => e
      Rails.logger.warn("[GithubOwnership] #{full_name}: #{e.class}: #{e.message}")
      verdict(:unavailable, full_name)
    end

    private

    def verdict(status, full_name)
      Verdict.new(status: status, full_name: full_name, message: MESSAGES[status])
    end
  end
end
