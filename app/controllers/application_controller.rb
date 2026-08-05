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

  def current_repository
    @current_repository ||= current_user.repositories.find(params[:repository_id] || params[:id])
  end
end
