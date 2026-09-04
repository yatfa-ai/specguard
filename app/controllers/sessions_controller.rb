# frozen_string_literal: true

class SessionsController < ApplicationController
  # `omniauth.origin` is whatever was in the request phase's `origin` parameter — a value the user
  # controls — so where it sends somebody is decided by the shared guard rather than here.
  include SafeReturnPath

  skip_forgery_protection only: %i[create failure]

  # Placeholder for the OmniAuth request phase. In a running app the OmniAuth middleware
  # intercepts POST /auth/github before it reaches here; this only fires if the middleware is
  # absent, which means the provider is misconfigured.
  def passthru
    redirect_to root_path, alert: "GitHub sign-in is not configured on this instance."
  end

  # The sign-in callback, and only that. It asks GitHub for identity — a handle, an avatar, an
  # email address — and nothing else; connecting repositories is a GitHub App installation and has
  # its own flow entirely (`GithubInstallationsController`).
  #
  # This used to serve both authorizations, because under the OAuth `repo` scope they were the same
  # exchange with a different scope on it. They are now different mechanisms, and nothing about a
  # sign-in touches what a user may register.
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

    # The session is being re-keyed to an identity GitHub just re-asserted, which is precisely when
    # session fixation is worth spending a `reset_session` on — and the destination below is read
    # from `omniauth.origin` (request env), not from the session, so nothing needed here is thrown
    # away by it.
    reset_session
    session[:user_id] = user.id

    redirect_to post_authorization_path, notice: signed_in_notice(user, returning)
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
  # this page's to disclose. But since SPGD-853 the state has TWO ways of being reached — the
  # person closed their own account from `/account`, or whoever operates the instance archived
  # them from the console — and this alert cannot tell which happened, so it answers both, in
  # the order the reader needs. A person who closed it themselves must hear first that nothing
  # in the product will reopen it (there is no restore surface — see the `refused, NOT
  # reactivated` note above), because anything else sends them hunting for an undo button that
  # does not exist. Only the unexpected case is pointed at the operator, because the console
  # that performed an unexpected archive is exactly theirs to ask. The previous copy named only
  # the second reader, which told a self-closed person to go find an admin authority the
  # product has never had.
  def refuse_archived(user)
    reset_session

    redirect_to root_path,
                alert: "The SpecGuard account for #{user.github_handle} has been archived and cannot sign in. " \
                       "If you closed it yourself, closure cannot be undone from within SpecGuard. " \
                       "If this was unexpected, contact whoever administers your SpecGuard instance."
  end

  # Where the user was when they were sent to GitHub, when that is somewhere they were sent *from*.
  def post_authorization_path
    safe_return_path(request.env["omniauth.origin"], fallback: repositories_path)
  end

  # Someone already signed in as this person re-authenticating is not news, and saying "Signed in
  # as octocat" to somebody who was already octocat reads as though something changed. The two
  # cases that remain are a fresh sign-in and a switch of account, and both are the same sentence.
  def signed_in_notice(user, returning)
    return nil if returning&.id == user.id

    "Signed in as #{user.github_handle}."
  end
end
