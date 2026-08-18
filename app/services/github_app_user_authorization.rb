# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Which installations does the person at the setup URL actually hold? — asked of GitHub, with a
# user token that exists for the length of this method call and is never written down.
#
#   GithubAppUserAuthorization.installations(code: params[:code])
#   # => [GithubAppUserAuthorization::Installation, …]
#
# ## Why this exists at all
#
# GitHub returns a user to the App's Setup URL after they install or reconfigure, carrying
# `?installation_id=N`. That parameter is a query string on a GET: anyone can type it, with anyone
# else's installation id in it. Recording it unchecked would hand the forger every repository in a
# stranger's installation — the squatting gap this whole slice exists to close, reopened at a wider
# gauge, since an installation is a set of repositories rather than one.
#
# So `installation_id` is treated as a claim and never as a fact. What settles it is the `code`
# GitHub sends alongside it — issued to that browser, single-use, and worthless to anyone who did
# not just complete the flow. Exchanged for a user-to-server token, it lets GitHub itself answer
# "which installations does this user have access to", and that answer is what gets recorded.
#
# ## What this token is, and what it is not
#
# It is a user-to-server token for a GitHub App. Its reach is bounded by the App's own permissions
# (Metadata: read-only) intersected with the user's own access — it cannot write anything, cannot
# read code, and cannot see a repository outside an installation. It is emphatically NOT the OAuth
# `repo` scope this slice removed, which was read-and-write over every repository the grantor could
# reach.
#
# It is used for one call and then goes out of scope. Nothing returns it, no column holds it, and no
# caller can ask for it — which is the same rule `GithubAppCredentials` follows for installation
# tokens, stated once more here because this is the one credential in the app that speaks for a
# *person*.
class GithubAppUserAuthorization
  # One installation this user can reach, as GitHub reports it. `account_login` rides along because
  # this endpoint already carries it — naming the connected account otherwise costs a second round
  # trip to an endpoint that exists only to answer that.
  Installation = Data.define(:installation_id, :account_login)

  TOKEN_URL = "https://github.com/login/oauth/access_token"
  API_ROOT = "https://api.github.com"

  # GitHub's maximum page size, and a ceiling on the walk. Someone reachable by more than 500
  # installations does not exist in practice; the bound is here so a malformed pagination response
  # cannot spin.
  PER_PAGE = 100
  MAX_PAGES = 5

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  class << self
    # Every installation GitHub says this user can access. Raises `GithubApi::Error` subclasses, so
    # a caller rescues the same family it does for every other GitHub call.
    #
    # An empty array is a real answer, not a failure: a user who authorized the App but selected no
    # repositories — or who cancelled out of the picker — legitimately holds nothing.
    def installations(code:)
      raise GithubApi::Unauthorized, "GitHub sent no authorization code." if code.blank?

      unless SpecGuard::GithubApp.configured?
        raise GithubAppCredentials::NotConfigured,
              "The SpecGuard GitHub App is not configured on this instance."
      end

      list(exchange(code))
    end

    private

    # `code` → user-to-server token. The token is returned into `installations`' local scope and
    # dies there.
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

      token
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
      Array(payload.is_a?(Hash) ? payload["installations"] : payload)
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
