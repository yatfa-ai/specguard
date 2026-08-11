# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_forgery_protection only: %i[create failure]

  # Placeholder for the OmniAuth request phase. In a running app the OmniAuth middleware
  # intercepts POST /auth/github before it reaches here; this only fires if the middleware is
  # absent, which means the provider is misconfigured.
  def passthru
    redirect_to root_path, alert: "GitHub sign-in is not configured on this instance."
  end

  # One callback for both authorizations, because to GitHub they are the same exchange and only
  # the requested scope differed. Signing in and connecting repositories therefore cannot drift
  # apart: whatever comes back is banked, and where the user lands is decided from what they were
  # doing, not from which button they pressed.
  def create
    auth = request.env["omniauth.auth"]
    return failure if auth.blank?

    returning = current_user
    user = User.from_github_omniauth(auth)

    # An archived person is refused HERE, after the identity upsert and before any session exists.
    #
    # Refused, NOT reactivated. Auto-clearing `archived_at` on a successful GitHub callback would
    # make archiving useless as an offboarding control: the archived person undoes it themselves by
    # visiting this URL. Coming back is a deliberate act by somebody else, and this slice does not
    # build that surface — so the only thing that happens here is a redirect.
    return refuse_archived(user) if user.archived?

    # Re-issued on every callback, including the repository one. The session is being re-keyed to
    # an identity GitHub just re-asserted, which is precisely when session fixation is worth
    # spending a `reset_session` on — and the destination below is read from `omniauth.origin`
    # (request env), not from the session, so nothing needed here is thrown away by it.
    reset_session
    session[:user_id] = user.id

    redirect_to post_authorization_path, **post_authorization_flash(user, returning)
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out."
  end

  def failure
    message = params[:message].presence || request.env["omniauth.error.type"].presence || "unknown_error"
    redirect_to root_path, alert: "GitHub sign-in failed (#{message})."
  end

  private

  # `reset_session` before the redirect, not merely "don't set `session[:user_id]`". Whatever
  # session arrived at this callback is now unwanted either way: if it was the archived person's
  # own, this is the moment to end it rather than leave them holding it until it expires; if it was
  # somebody else's on a shared browser, an authorization we just refused is not a reason to keep
  # them signed in. `ApplicationController#current_user` scopes to `User.active` as well, so the
  # refusal does not rest on this line alone.
  #
  # The alert names no reason beyond "archived" — why a particular person was offboarded is not
  # this page's to disclose, and there is nothing they can do here about it.
  def refuse_archived(user)
    reset_session

    redirect_to root_path,
                alert: "The SpecGuard account for #{user.github_handle} has been archived and cannot sign in. " \
                       "If this is unexpected, contact whoever administers your SpecGuard instance."
  end

  # Where the user was when they were sent to GitHub, when that is somewhere they were sent *from*.
  # `omniauth.origin` is whatever was in the request phase's `origin` parameter — a value the user
  # controls — so it is admitted only as a path on this site. An absolute URL, a protocol-relative
  # `//evil.example`, or anything else is discarded rather than corrected: this is the last hop of
  # an authorization flow, which is the single most attractive open redirect an app has.
  def post_authorization_path
    origin = request.env["omniauth.origin"].to_s

    return repositories_path unless origin.start_with?("/")
    return repositories_path if origin.start_with?("//", "/\\")

    origin
  end

  # Three different things just happened and they read differently to whoever did them: a person
  # signed in, a signed-in person connected their repositories, or a signed-in person came back
  # from the consent screen without granting what was asked for. The third is the one worth
  # catching — GitHub returns a perfectly valid token with narrower scopes when an organization's
  # policy blocks the grant, and the only symptom otherwise is an empty repository list on the
  # next page with nothing saying why.
  def post_authorization_flash(user, returning)
    if returning.nil? || returning.id != user.id
      { notice: "Signed in as #{user.github_handle}." }
    elsif user.github_repository_access?
      { notice: "GitHub repositories connected." }
    else
      { alert: "GitHub did not grant repository access. If your repositories belong to an " \
               "organization, that organization may need to approve SpecGuard." }
    end
  end
end
