# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_forgery_protection only: %i[create failure]

  # Placeholder for the OmniAuth request phase. In a running app the OmniAuth middleware
  # intercepts POST /auth/github before it reaches here; this only fires if the middleware is
  # absent, which means the provider is misconfigured.
  def passthru
    redirect_to root_path, alert: "GitHub sign-in is not configured on this instance."
  end

  def create
    auth = request.env["omniauth.auth"]
    return failure if auth.blank?

    user = User.from_github_omniauth(auth)
    reset_session
    session[:user_id] = user.id

    redirect_to repositories_path, notice: "Signed in as #{user.github_handle}."
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out."
  end

  def failure
    message = params[:message].presence || request.env["omniauth.error.type"].presence || "unknown_error"
    redirect_to root_path, alert: "GitHub sign-in failed (#{message})."
  end
end
