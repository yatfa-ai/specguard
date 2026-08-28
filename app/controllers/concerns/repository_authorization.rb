# frozen_string_literal: true

# THE RESOLVE-AND-AUTHORIZE SEAM FOR A REPOSITORY NAMED IN THE REQUEST, shared by both controller
# trees — the browser one (`ApplicationController`) and the machine one (`Api::BaseController`).
#
# ## Why a concern, and why now
#
# Until SPGD-754 these three methods were private on `ApplicationController`, which meant the same
# three questions asked in a browser and asked over the API were answered by two implementations
# that could drift: a change to who may do what could land on one surface and miss the other, and
# nothing would say so. A capability question is one rule; this module is the one place it lives.
# Both trees include it, so the fork below holds identically on `/repositories/1/api_keys` and on
# `/api/v1/repositories/1/api_keys` because it is the same code answering.
#
# ## The seam: `authorizing_user`, not `current_user`
#
# The two trees name their principal DIFFERENTLY and deliberately. `ApplicationController#current_user`
# means "the person holding this browser session"; `Api::BaseController#current_api_user` means "the
# person named by a token, with no session anywhere near it" — its comment says why in as many words.
# Collapsing the two into one name would erase a distinction that exists precisely so nobody mistakes
# a session for a token. So this module does not say either name: it asks `authorizing_user`, which
# each tree answers with its own (`current_user` on the web base, `current_api_user` on the API base).
# Both existing names stay exactly as they are.
#
# ## The failure shapes are deliberate and must survive every move
#
#   - not a member of the repository -> `ActiveRecord::RecordNotFound`, which the WEB tree's
#     middleware answers 404 with: the repository's existence stays hidden, exactly as it did when
#     this method scoped `.find` to `current_user.repositories`.
#   - a member without this particular permission -> `SpecGuard::NotAuthorized`: they can already
#     see the repository, so 404 would be a lie.
#
# On the web, `config/application.rb` maps both exceptions to status codes at the middleware level
# and nothing changes. On the API there is no such wiring — `Api::BaseController` registers its own
# `rescue_from` for both so the fork survives as `{error:, message:}` JSON rather than Rails' default
# public-exception page. The two trees differ in how they RENDER a refusal, not in who gets one.
#
# ## Memoization: the lookup yes, the verdict no, the policy per repository
#
# The lookup is memoized; the authorization deliberately is not — memoizing the RESULT would mean a
# second call with a different capability silently reused the first call's verdict.
# `repository_policy` is memoized per repository and shared with `authorize_repository!`, so a page
# asking several capabilities loads the membership row once.
module RepositoryAuthorization
  extend ActiveSupport::Concern

  private

  # Resolves the repository named in the URL *and* authorizes the current action against it, in one
  # call, because every caller needs both and separating them invites a call site that forgets the
  # second. `capability` is a key of RepositoryPolicy::CAPABILITIES.
  #
  # `capability` is OPTIONAL and nil means "resolve only, do not authorize". That default exists for
  # exactly one caller: `Api::V1::IngestsController`, whose `current_repository` is not named in the
  # URL at all — it is the repository the `sgk_` key itself names, bound by `Api::BaseController`
  # during authentication, and the ingest contract is that authentication IS the authorization for
  # that credential. Everything else passes a capability, and a reader who sees a call without one
  # is looking at the key-bound case.
  def current_repository(capability = nil)
    @current_repository ||= Repository.find_by(id: params[:repository_id] || params[:id])

    capability ? authorize_repository!(@current_repository, capability) : @current_repository
  end

  def authorize_repository!(repository, capability)
    policy = repository_policy(repository)

    raise ActiveRecord::RecordNotFound if repository.nil? || !policy.member?
    raise SpecGuard::NotAuthorized unless policy.can?(capability)

    repository
  end

  # Memoized per repository, and shared with `authorize_repository!` above, so a page that asks
  # several capabilities loads the membership row once rather than once per question.
  #
  # Exposed to views on the web tree via `helper_method :repository_policy` on
  # `ApplicationController` — a template is a call site of this policy like any other; see the note
  # there. On the API tree nothing renders a view and the method is simply private.
  def repository_policy(repository = @current_repository)
    @repository_policies ||= Hash.new { |cache, repo| cache[repo] = RepositoryPolicy.new(authorizing_user, repo) }
    @repository_policies[repository]
  end
end
