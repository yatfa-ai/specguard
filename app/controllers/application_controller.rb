# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  default_form_builder Forms::FormBuilder

  helper_method :current_user, :signed_in?, :github_oauth_configured?, :repository_policy

  private

  # Scoped to `User.active`, so archiving somebody takes effect on the session they are ALREADY
  # holding rather than only the next time they try to sign in. Without this, an offboarding
  # control is one a signed-in person simply outlasts — they keep full access until their session
  # expires, which is the one window where it matters most. Everything downstream (`signed_in?`,
  # `require_authentication`, `repository_policy`) reads through here, so this single call site
  # carries the whole app.
  #
  # `User.active` is an explicit scope, not a `default_scope` — see the note on the model. This is
  # the read site that opts in; association traversals deliberately still see archived rows, so a
  # membership or an API key an archived person left behind keeps naming them.
  def current_user
    @current_user ||= User.active.find_by(id: session[:user_id]) if session[:user_id]
  end

  def signed_in?
    current_user.present?
  end

  def github_oauth_configured?
    SpecGuard::GithubOauth.configured?
  end

  def require_authentication
    return if signed_in?

    redirect_to root_path, alert: "Sign in with GitHub to continue."
  end

  # Resolves the repository named in the URL *and* authorizes the current action against it, in one
  # call, because every caller needs both and separating them invites a call site that forgets the
  # second. `capability` is a key of RepositoryPolicy::CAPABILITIES.
  #
  # The two failure shapes are deliberate:
  #   - not a member of the repository -> 404. Its existence stays hidden, exactly as it was when
  #     this method scoped `.find` to `current_user.repositories`.
  #   - a member without this particular permission -> 403. They can already see the repository, so
  #     404 would be a lie.
  # The lookup is memoized; the authorization deliberately is not. Memoizing the *result* would
  # mean a second call with a different capability silently reused the first call's verdict.
  def current_repository(capability)
    @current_repository ||= Repository.find_by(id: params[:repository_id] || params[:id])

    authorize_repository!(@current_repository, capability)
  end

  def authorize_repository!(repository, capability)
    policy = repository_policy(repository)

    raise ActiveRecord::RecordNotFound if repository.nil? || !policy.member?
    raise SpecGuard::NotAuthorized unless policy.can?(capability)

    repository
  end

  # Exposed to views (`helper_method` above) so a template can ask the same question the controller
  # asked. Every control on repositories/show links to an action `current_repository` authorizes, so
  # rendering one the viewer does not hold is an affordance that can only ever produce a 403 — and
  # for "Remove" that means a destructive confirm dialog followed by an error page. A view is a call
  # site of this policy like any other.
  #
  # Memoized per repository, and shared with `authorize_repository!` above, so a page that asks
  # several capabilities loads the membership row once rather than once per question.
  def repository_policy(repository = @current_repository)
    @repository_policies ||= Hash.new { |cache, repo| cache[repo] = RepositoryPolicy.new(current_user, repo) }
    @repository_policies[repository]
  end
end
