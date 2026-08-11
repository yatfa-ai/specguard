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
# Six different things can stop a registration and five of them are the user's to fix, each in a
# different way: authorize the app, re-authorize a revoked token, pick a repository you actually
# administer, check the spelling, wait out a rate limit. A boolean collapses all of them into
# "no", which is how a UI ends up telling someone to fix the wrong thing. Every non-verified status
# carries the sentence the form should show, and `reauthorize?` marks the two the user resolves by
# granting access rather than by editing the field.
class GithubOwnership
  # `:verified`   GitHub reports this user as an admin of this repository. The only pass.
  # `:not_connected`  no usable token, or one whose granted scopes cannot read repositories.
  # `:token_rejected` GitHub rejected the token — revoked on GitHub's side, or expired.
  # `:not_admin`      the repository is visible to this user, who is not an admin of it. This is
  #                   the squatting case, and the one the gap was.
  # `:not_found`      invisible to this token. NOT "does not exist" — GitHub answers 404 for a
  #                   private repository the caller cannot read, so the message must cover both.
  # `:unavailable`    GitHub could not be reached or would not answer. Explicitly not a pass:
  #                   an outage must fail closed, or the gap reopens on every 500.
  Verdict = Data.define(:status, :full_name, :message) do
    def verified? = status == :verified

    # The two the user fixes by granting access, not by changing what they typed — so the form can
    # offer the authorize button instead of an error the field cannot resolve.
    def reauthorize? = %i[not_connected token_rejected].include?(status)
  end

  MESSAGES = {
    not_connected: "could not be verified — connect your GitHub repositories first.",
    token_rejected: "could not be verified — your GitHub authorization is no longer valid. " \
                    "Reconnect and try again.",
    not_admin: "is not a repository you administer on GitHub. Only an admin of a repository " \
               "can register it here.",
    not_found: "was not found on GitHub, or is not visible to your GitHub account.",
    unavailable: "could not be verified — GitHub did not answer. Try again shortly."
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
    rescue GithubApi::Forbidden, GithubApi::Unavailable => e
      # Logged rather than shown: a 403 from GitHub can name an organization's SSO policy, and the
      # form's job is to say "try again", not to relay GitHub's operational detail to the browser.
      Rails.logger.warn("[GithubOwnership] #{full_name}: #{e.class}: #{e.message}")
      verdict(:unavailable, full_name)
    end

    private

    def verdict(status, full_name)
      Verdict.new(status: status, full_name: full_name, message: MESSAGES[status])
    end
  end
end
