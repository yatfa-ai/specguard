# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  default_form_builder Forms::FormBuilder

  helper_method :current_user, :signed_in?, :github_oauth_configured?

  private

  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id]
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
    policy = RepositoryPolicy.new(current_user, repository)

    raise ActiveRecord::RecordNotFound if repository.nil? || !policy.member?
    raise SpecGuard::NotAuthorized unless policy.can?(capability)

    repository
  end
end
