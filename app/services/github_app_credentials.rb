# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

# Installation access tokens — the credential SpecGuard reads GitHub with, minted on demand and
# never written down.
#
#   GithubAppCredentials.installation_token(42)  # => "ghs_…", good for the next hour
#
# ## Why nothing is persisted
#
# The OAuth path this replaces stored a long-lived user token in an encrypted column, which meant a
# database dump carried live credentials for every user's repositories. An installation token is
# minted from the App's private key whenever it is needed, expires in an hour on GitHub's side, and
# lives only in this process's memory until then. There is no column to leak and nothing to revoke:
# a user who uninstalls the App makes every future mint fail, immediately, with no state here to
# clean up.
#
# The in-process cache exists because a single page render can ask GitHub several questions and
# minting is itself a round trip. It is deliberately a plain constant rather than `Rails.cache`:
# `Rails.cache` may be a shared store (Redis, the database, a file), and a credential that reaches
# repository metadata does not belong in one. Losing the cache on restart costs one extra round
# trip and nothing else.
#
# ## The JWT
#
# GitHub authenticates the App itself with a short-lived RS256 JWT signed by the App's private key.
# It is ~15 lines of OpenSSL, so it is written out here rather than taken as a dependency: the `jwt`
# gem is present in the lockfile only as a transitive dependency of `omniauth-github`, and reaching
# past `Gemfile` into another gem's dependency tree is how a `bundle update` elsewhere breaks
# authentication here.
#
# ## Errors
#
# Everything surfaces as a `GithubApi::Error` subclass, so a caller rescues one family across
# minting and reading alike:
#
#   NotConfigured  the App has no credentials on this instance. A subclass of `Unavailable`, so it
#                  fails CLOSED — an unconfigured instance registers nothing rather than everything.
#   Unauthorized   GitHub rejected the JWT: wrong App id, or a private key that is not this App's.
#   NotFound       no such installation. This is what an *uninstall* looks like from here, and it
#                  is the ordinary way a stored installation stops working.
#   Unavailable    transport failure, timeout, 5xx, or a body that is not the JSON promised.
class GithubAppCredentials
  # Raised when the App is not configured on this instance. `Unavailable` rather than a class of its
  # own so every caller's existing rescue already fails closed on it; the message is what tells an
  # operator which of the three values is missing.
  NotConfigured = Class.new(GithubApi::Unavailable)

  API_ROOT = "https://api.github.com"

  # GitHub rejects a JWT whose lifetime exceeds ten minutes. Nine leaves room for the clock skew
  # GitHub itself warns about without going near the ceiling.
  JWT_TTL = 9 * 60

  # GitHub backdates `iat` by up to 60s worth of tolerance; sending a token issued slightly in the
  # past is the documented remedy for a server clock that runs fast, which is otherwise a 401 that
  # looks exactly like a wrong key.
  JWT_CLOCK_SKEW = 60

  # Re-mint this long before GitHub's stated expiry. An installation token is good for an hour; a
  # request that starts at 59:59 with a token fetched from cache must not fail on arrival.
  EXPIRY_MARGIN = 5 * 60

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  @cache = {}
  @mutex = Mutex.new

  class << self
    # A usable installation token, from cache when one is still comfortably live and from GitHub
    # otherwise.
    #
    # The mint happens OUTSIDE the lock. Holding a mutex across a network call would serialize every
    # request in the process behind one slow GitHub round trip, and the cost of two concurrent
    # requests both minting is one redundant token that GitHub is perfectly happy to have issued.
    def installation_token(installation_id)
      id = installation_id.to_i
      raise GithubApi::NotFound, "GitHub installation id is missing." unless id.positive?

      cached = @mutex.synchronize { @cache[id] }
      return cached.first if cached && cached.last > Time.current + EXPIRY_MARGIN

      token, expires_at = mint(id)
      @mutex.synchronize { @cache[id] = [token, expires_at] }
      token
    end

    # Drops every cached token. For the suite and the console; nothing on a request path calls it.
    def reset! = @mutex.synchronize { @cache.clear }

    # The App's own credential, for the handful of endpoints that are about the App rather than
    # about one installation. Public because `GithubApi` authenticates App-level reads with it.
    def app_jwt
      key = private_key
      now = Time.current.to_i

      encode({ typ: "JWT", alg: "RS256" },
             { iat: now - JWT_CLOCK_SKEW, exp: now + JWT_TTL, iss: SpecGuard::GithubApp.app_id.to_s },
             key)
    end

    private

    def mint(installation_id)
      payload = post("/app/installations/#{installation_id}/access_tokens")
      token = payload["token"].to_s
      raise GithubApi::Unavailable, "GitHub issued no installation token." if token.empty?

      [token, parse_expiry(payload["expires_at"])]
    end

    # GitHub always sends `expires_at`, but a missing or unparseable one must not be read as "never
    # expires" — that would cache a dead token forever. An unreadable expiry is treated as an hour,
    # which is GitHub's documented lifetime, minus the usual margin on the way out.
    def parse_expiry(value)
      Time.zone.parse(value.to_s) || 1.hour.from_now
    rescue ArgumentError, TypeError
      1.hour.from_now
    end

    def private_key
      unless SpecGuard::GithubApp.configured?
        raise NotConfigured,
              "The SpecGuard GitHub App is not configured on this instance. Set GITHUB_APP_ID, " \
              "GITHUB_APP_SLUG and GITHUB_APP_PRIVATE_KEY (see config/initializers/github_app.rb)."
      end

      OpenSSL::PKey::RSA.new(SpecGuard::GithubApp.private_key)
    rescue OpenSSL::PKey::RSAError => e
      # A malformed PEM is a configuration mistake, not a GitHub outage — but it must still fail
      # closed, and `NotConfigured` is exactly "this instance cannot talk to GitHub as the App".
      raise NotConfigured, "The SpecGuard GitHub App private key could not be read: #{e.message}"
    end

    # RS256 over `base64url(header).base64url(payload)`, which is the whole of a JWT.
    def encode(header, payload, key)
      signing_input = [header, payload].map { |part| base64url(JSON.generate(part)) }.join(".")
      signature = key.sign(OpenSSL::Digest.new("SHA256"), signing_input)

      "#{signing_input}.#{base64url(signature)}"
    end

    # Base64 *url* encoding, unpadded — a standard `=`-padded encoding is rejected by GitHub.
    def base64url(value) = Base64.urlsafe_encode64(value, padding: false)

    def post(path)
      uri = URI.parse("#{API_ROOT}#{path}")
      parse(perform(uri))
    end

    def perform(uri)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{app_jwt}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      request["User-Agent"] = "SpecGuard"

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                              open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end
    rescue GithubApi::Error
      # `app_jwt` is evaluated inside this block, so a configuration failure would otherwise be
      # swallowed by the broad rescue below and reported as "GitHub could not be reached".
      raise
    rescue StandardError => e
      # Deliberately broad, for the reason `GithubApi#perform` states in full: the ancestors
      # Net::HTTP raises are a list that goes stale silently, and every one of them means the same
      # thing to a caller.
      raise GithubApi::Unavailable, "GitHub token request failed: #{e.class}: #{e.message}"
    end

    def parse(response)
      case response
      when Net::HTTPSuccess then decode(response.body)
      when Net::HTTPUnauthorized
        raise GithubApi::Unauthorized,
              "GitHub rejected the SpecGuard App credentials. Check GITHUB_APP_ID and the private key."
      when Net::HTTPNotFound
        raise GithubApi::NotFound, "GitHub has no such App installation; it may have been uninstalled."
      when Net::HTTPForbidden then raise GithubApi::Forbidden.new("GitHub refused the token request.")
      else raise GithubApi::Unavailable, "GitHub responded #{response.code} to a token request."
      end
    end

    def decode(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError => e
      raise GithubApi::Unavailable, "GitHub returned a body that is not JSON: #{e.message}"
    end
  end
end
