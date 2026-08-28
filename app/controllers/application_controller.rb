# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  default_form_builder Forms::FormBuilder

  # The resolve-and-authorize seam for a repository named in the URL — `current_repository`,
  # `authorize_repository!`, `repository_policy` — shared with the API tree so that who may do
  # what is one rule answered by one implementation on both surfaces. See the module for the seam
  # this class answers below (`#authorizing_user`).
  include RepositoryAuthorization

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

  # How `RepositoryAuthorization` names THIS tree's principal. The web's principal is the person
  # holding the browser session, which is what `current_user` has always meant here. The API tree
  # answers the same seam with `current_api_user` — see `Api::BaseController#authorizing_user` and
  # the module's header for why the two are deliberately not one name.
  def authorizing_user
    current_user
  end
end
