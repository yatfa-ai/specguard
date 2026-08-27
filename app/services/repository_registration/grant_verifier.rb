# frozen_string_literal: true

# REDEEM WHAT GITHUB SAID EARLIER — the verifier for a request that has a person and no way to ask
# GitHub about them. See {GithubRegistrationGrant} for what a grant is and why one exists.
#
# ## It speaks the live path's vocabulary rather than inventing its own
#
# Every answer here is an `InstallationRepositories::Verdict` built from that class's own `MESSAGES`
# hash. That is deliberate and it is the point of this class being this small: the refusal wording,
# and the `errors.add(:github_full_name, verdict.message)` shape it lands in, are SHARED with the
# web path rather than duplicated beside it. A repository a person cannot register is refused in one
# sentence whichever surface they came through.
#
# ## Fails closed, in both of the two ways it can
#
# A person with NO grant registers nothing, and a person whose grant is past
# `GithubRegistrationGrant::MAX_AGE` registers nothing. `InstallationRepositories.sources` sets the
# precedent for the first — `return blank_sources(installed: true, error: :not_authorized) if
# user_token.blank?` — and the second is the whole reason the snapshot is stamped. Both land on
# `:not_granted`, which is a DIFFERENT sentence from the two refusals below it: those say GitHub has
# answered and the answer was no, and this says SpecGuard has not got a current answer to give. The
# fix is different too, and the sentence names it — reconnect in a browser.
#
# ## Why the grant carries a "visible" set it never grants from
#
# `registrable_full_names` is the only thing that permits anything. `visible_full_names` decides
# WHICH refusal is true, and nothing else. Without it, the ordinary non-admin member of an
# organization would be told their repository "is not one of the repositories the SpecGuard GitHub
# App is installed on" — which is false, is not the thing they need to fix, and would send them to
# GitHub's installation settings to look for something already there.
class RepositoryRegistration
  class GrantVerifier
    def initialize(grant:)
      @grant = grant
    end

    def verdict_for(full_name)
      name = full_name.to_s.strip

      return verdict(:not_granted, name) if @grant.nil? || @grant.stale?
      return verdict(:verified, name) if @grant.registrable?(name)
      return verdict(:not_administered, name) if @grant.visible?(name)

      verdict(:not_in_installation, name)
    end

    private

    # `MESSAGES[status]` and not `.fetch`, matching `InstallationRepositories.verdict` exactly:
    # `:verified` deliberately has no entry, because a pass has nothing to say to anybody. Every
    # refusal this class can produce does have one.
    def verdict(status, full_name)
      InstallationRepositories::Verdict.new(status: status, full_name: full_name,
                                            message: InstallationRepositories::MESSAGES[status])
    end
  end
end
