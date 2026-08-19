# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Who is the person GitHub just sent back, and what can they reach? — asked of GitHub with a
# user-to-server token obtained from the single-use `code` they arrived carrying.
#
#   authorization = GithubAppUserAuthorization.authorize(code: params[:code])
#   authorization.installations  # => [GithubAppUserAuthorization::Installation, …]
#   authorization.token          # => "ghu_…", the credential every later read is made with
#
# ## Why this exists at all
#
# GitHub returns a user to the App after they install, reconfigure, or merely re-authorize, and on
# an install it carries `?installation_id=N`. That parameter is a query string on a GET: anyone can
# type it, with anyone else's installation id in it. Recording it unchecked would hand the forger
# every repository in a stranger's installation — the squatting gap this whole slice exists to
# close, reopened at a wider gauge, since an installation is a set of repositories rather than one.
#
# So `installation_id` is treated as a claim and never as a fact. What settles it is the `code`
# GitHub sends alongside it, exchanged for a user-to-server token, which lets GitHub itself answer
# "which installations does this user have access to".
#
# The `code` is not self-evidently trustworthy either, and the direction of the risk is the
# unobvious one. It is single-use and short-lived, so a STOLEN code is a poor prize; a PLANTED one
# is the problem. The callback is a GET, Rails applies no CSRF check to a GET, and `state` is a
# return path rather than a nonce — so a signed-in user can be made to load this URL carrying a code
# somebody else generated for their own GitHub account and deliberately left unredeemed. The
# exchange would succeed and hand the victim's session a credential that speaks for the attacker.
# `authorize` therefore takes the signed-in identity and refuses a code that belongs to anybody
# else; see the note on it.
#
# ## What this token is, what it is not, and why it is now returned
#
# It is a user-to-server token for a GitHub App. Its reach is the App's own permissions (Metadata:
# read-only) intersected with the user's own access — it cannot write anything, cannot read code,
# and cannot see a repository outside an installation. It is emphatically NOT the OAuth `repo`
# scope this slice removed, which was read-and-write over every repository the grantor could reach.
#
# An earlier draft of this class discarded the token after one call, on the principle that a
# credential should not outlive its usefulness. It turned out to be useful for longer than that: it
# is the ONLY credential that can answer "which of these repositories does THIS user administer",
# and an installation token — which speaks for the App and knows nothing about who is asking —
# cannot. So the token is returned to the caller, which holds it in the user's SESSION for as long
# as that session lasts. It reaches no database column, no log, and no other user; when the session
# ends it is gone, and the next one is obtained by a silent trip back through
# `SpecGuard::GithubApp.authorization_url`.
class GithubAppUserAuthorization
  # One installation this user can reach, as GitHub reports it. `account_login` rides along because
  # this endpoint already carries it — naming the connected account otherwise costs a second round
  # trip to an endpoint that exists only to answer that.
  Installation = Data.define(:installation_id, :account_login)

  # What one completed round trip through GitHub produced. The token and the installations travel
  # together because they are two halves of one answer: the installations are only meaningful to
  # the user this token speaks for, and reading them later needs the token that read them now.
  Authorization = Data.define(:token, :expires_at, :installations)

  TOKEN_URL = "https://github.com/login/oauth/access_token"
  API_ROOT = "https://api.github.com"

  # GitHub's maximum page size, and a ceiling on the walk. Someone reachable by more than 500
  # installations does not exist in practice; the bound is here so a malformed pagination response
  # cannot spin.
  PER_PAGE = 100
  MAX_PAGES = 5

  # What a token is assumed to be good for when GitHub does not say. An App with "expire user
  # authorization tokens" ON returns `expires_in` (28800, eight hours) and one with it OFF returns
  # nothing, in which case the token does not expire on GitHub's side at all. An hour is used for
  # the silent case deliberately: holding a non-expiring credential in a session for a week is not
  # something to do by omission, and the cost of being wrong is one invisible redirect.
  DEFAULT_TTL = 1.hour

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  class << self
    # Turn the `code` GitHub sent back into a token and the installations it can reach, having first
    # established that the token speaks for the person who is signed in. Raises `GithubApi::Error`
    # subclasses, so a caller rescues the same family it does for every other GitHub call.
    #
    # An empty `installations` is a real answer, not a failure: a user who authorized the App but
    # selected no repositories — or who cancelled out of the picker — legitimately holds nothing.
    #
    # ## `github_uid` is required, and is the whole of what makes the callback safe
    #
    # The callback is a GET. Rails applies no CSRF check to one, and `state` is a return path rather
    # than a nonce, so a signed-in user can be made to load this URL carrying a `code` somebody else
    # obtained — a code they generated in their own browser, for their own GitHub account, and then
    # never redeemed. Without this check the exchange would succeed, and the victim's session would
    # be handed a credential that speaks for the ATTACKER, along with rows for the attacker's
    # installations: a repository the victim has no relationship with becomes registerable under the
    # victim's account, and `github_full_name` is globally unique.
    #
    # So the identity behind the token is read from GitHub and compared with the identity the
    # session already claims. A code minted for anybody else is refused, whatever it is otherwise
    # worth. It is a keyword without a default deliberately: a caller cannot forget it.
    def authorize(code:, github_uid:)
      raise GithubApi::Unauthorized, "GitHub sent no authorization code." if code.blank?
      raise GithubApi::Unauthorized, "No signed-in identity to bind the authorization to." if github_uid.blank?

      unless SpecGuard::GithubApp.configured?
        raise GithubApi::NotConfigured,
              "The SpecGuard GitHub App is not configured on this instance."
      end

      token, expires_at = exchange(code)
      bind_to_identity(token, github_uid)

      Authorization.new(token: token, expires_at: expires_at, installations: list(token))
    end

    private

    # `GET /user` with the freshly exchanged token: GitHub's own answer to "whose token is this".
    # Compared against the `github_uid` the session was established with, which is GitHub's stable
    # numeric id for the account and is the same id whichever of the two Apps issued the credential.
    #
    # A body that carries no id is a mismatch rather than a pass — the point of the call is to be
    # told who this is, and "GitHub did not say" is not being told.
    def bind_to_identity(token, github_uid)
      uri = URI.parse("#{API_ROOT}/user")
      payload = get(uri, token)
      uid = payload.is_a?(Hash) ? payload["id"].to_s : ""

      return if uid.present? && uid == github_uid.to_s

      raise GithubApi::Unauthorized,
            "GitHub says that authorization belongs to a different account."
    end

    # `code` → `[user-to-server token, when it stops being usable]`.
    def exchange(code)
      payload = post_form(URI.parse(TOKEN_URL),
                          client_id: SpecGuard::GithubApp.client_id,
                          client_secret: SpecGuard::GithubApp.client_secret,
                          code: code)

      # GitHub answers 200 with `{"error": "bad_verification_code"}` for a code that is expired,
      # already used, or simply invented — the status line alone would read that as success.
      if payload["error"].present?
        raise GithubApi::Unauthorized, "GitHub refused the authorization code (#{payload['error']})."
      end

      token = payload["access_token"].to_s
      raise GithubApi::Unauthorized, "GitHub returned no access token." if token.empty?

      [token, expiry_from(payload)]
    end

    # Shortened by a minute so a token that expires while a request is in flight is treated as
    # expired before it is used rather than after GitHub rejects it.
    def expiry_from(payload)
      seconds = payload["expires_in"].to_i
      seconds = DEFAULT_TTL.to_i unless seconds.positive?

      Time.current + [seconds - 60, 0].max.seconds
    end

    def list(token)
      installations = []

      (1..MAX_PAGES).each do |page|
        batch = page_of_installations(token, page)
        installations.concat(batch.filter_map { |payload| installation_from(payload) })

        break if batch.length < PER_PAGE
      end

      installations.uniq(&:installation_id)
    end

    def page_of_installations(token, page)
      uri = URI.parse("#{API_ROOT}/user/installations")
      uri.query = URI.encode_www_form(per_page: PER_PAGE, page: page)

      payload = get(uri, token)

      # This endpoint answers with an object — `{total_count:, installations: […]}` — and is
      # defaulted to `[]` so a body of an unexpected shape ends the walk rather than raising a
      # NoMethodError several frames up.
      Array(payload.is_a?(Hash) ? payload["installations"] : payload).grep(Hash)
    end

    def installation_from(payload)
      id = payload["id"].to_i
      return nil unless id.positive?

      Installation.new(installation_id: id, account_login: payload.dig("account", "login").presence)
    end

    def post_form(uri, **form)
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "SpecGuard"
      request.set_form_data(form)

      parse(perform(uri, request))
    end

    def get(uri, token)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      request["User-Agent"] = "SpecGuard"

      parse(perform(uri, request))
    end

    def perform(uri, request)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                              open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end
    rescue StandardError => e
      # Deliberately broad, for the reason `GithubApi#perform` states in full.
      raise GithubApi::Unavailable, "GitHub request failed: #{e.class}: #{e.message}"
    end

    def parse(response)
      case response
      when Net::HTTPSuccess then decode(response.body)
      when Net::HTTPUnauthorized then raise GithubApi::Unauthorized, "GitHub rejected the authorization."
      when Net::HTTPForbidden then raise GithubApi::Forbidden.new("GitHub refused the request.")
      when Net::HTTPNotFound then raise GithubApi::NotFound, "GitHub has no such resource."
      else raise GithubApi::Unavailable, "GitHub responded #{response.code}."
      end
    end

    def decode(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) || parsed.is_a?(Array) ? parsed : {}
    rescue JSON::ParserError => e
      raise GithubApi::Unavailable, "GitHub returned a body that is not JSON: #{e.message}"
    end
  end
end
