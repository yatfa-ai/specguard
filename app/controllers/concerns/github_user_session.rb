# frozen_string_literal: true

# The signed-in user's GitHub credential, for as long as they are signed in and not one moment
# longer.
#
# Reading a user's repositories takes a credential that speaks for THAT USER — an installation
# token speaks for the App and cannot tell one member of an organization from another, which is the
# whole reason `InstallationRepositories` asks with a user token. So one has to be kept somewhere
# between the round trip that obtains it and the pages that read with it.
#
# ## Why the session and not a column
#
# The OAuth path this slice replaced kept a long-lived `repo` token in an encrypted column, which
# meant a database dump carried live read-and-write credentials for every user's repositories. That
# column is gone and nothing here brings it back:
#
#   - The token reaches no table, no log and no other user, and it goes when the session does —
#     `reset_session` on sign-out clears it, and so does the `reset_session` on the way IN, which is
#     what stops a second person signing in on a shared browser from inheriting the first person's
#     credential. The cost of that is a returning user paying one invisible redirect per session;
#     the alternative is a credential outliving the identity it was issued to.
#   - Being honest about what that costs: this app uses Rails' default cookie session store, so the
#     token is encrypted and signed with `secret_key_base` but is held BY THE BROWSER and travels on
#     every request. `reset_session` stops this app honouring the old session; it cannot reach out
#     and destroy a cookie somebody has already copied, which stays usable until the stored expiry.
#     That is the same exposure the session itself already has, over a strictly narrower credential
#     than the `repo` token this replaced, and it is bounded by an expiry that column was not.
#   - It is far narrower than what it replaced: a user-to-server token for the SpecGuard App,
#     bounded by the App's declared permissions (Metadata: read-only) intersected with the user's
#     own access. It cannot write anything and cannot read code.
#   - It is treated as expired ahead of GitHub's own deadline (`GithubAppUserAuthorization`), and a
#     missing or expired one is an ordinary state with a one-click fix rather than an error — for
#     somebody who has already authorized the App, GitHub renders no screen at all and the round
#     trip is invisible.
#
# The alternative — re-authorizing on every page that lists repositories — is a github.com round
# trip per page render, which is worse for the user and no better for the credential.
module GithubUserSession
  extend ActiveSupport::Concern

  TOKEN_KEY = "github_user_token"
  EXPIRES_KEY = "github_user_token_expires_at"

  included do
    # `github_user_token` is deliberately NOT a helper method. No view has anything to do with the
    # credential itself, and a helper is one careless `<%= %>` away from rendering it into a page.
    helper_method :github_authorization_needed?
  end

  private

  # The viewer's GitHub credential, or `nil` when this session has none that can still be used.
  #
  # An expired token is reported as absent rather than handed out and allowed to fail: the two are
  # the same situation to every caller, and the difference would only show up as a GitHub 401 one
  # round trip later.
  def github_user_token
    return nil unless github_user_token_live?

    session[TOKEN_KEY].presence
  end

  # Anything unreadable is expired. Only this app writes the value and the session is signed, so a
  # malformed stamp is a bug rather than an attack — but the safe reading of "I cannot tell when
  # this expires" is "it has", and `Time.zone.parse` answers a bad string with nil for some inputs
  # and an ArgumentError for others.
  def github_user_token_live?
    expires_at = session[EXPIRES_KEY]
    return false if expires_at.blank?

    Time.zone.parse(expires_at.to_s).to_i > Time.current.to_i
  rescue ArgumentError
    false
  end

  # Called only from the callback, and only with a token `GithubAppUserAuthorization` has already
  # refused to return empty — so there is no blank-token branch here. A blank one would be harmless
  # anyway: `github_user_token` reads it back through `presence`.
  def store_github_user_token(token, expires_at:)
    session[TOKEN_KEY] = token
    session[EXPIRES_KEY] = expires_at.iso8601
  end

  # Whether the fix on offer is "let SpecGuard ask GitHub about you again". True for a user who has
  # connected an installation at some point — so there is something to read — but whose session
  # holds no usable credential to read it with.
  #
  # Asked of `User#github_installed?` rather than of a GitHub read, for the reason
  # `GithubRepositoryListing#github_installation_needed?` states: it is one `EXISTS` against our own
  # table, and it decides whether a page shows the reconnect button or the install button before
  # anything has called GitHub at all.
  def github_authorization_needed?
    github_user_token.nil? && current_user&.github_installed?.present?
  end
end
