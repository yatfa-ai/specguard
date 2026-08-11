# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# The GitHub REST client — the app's only way to ask GitHub a question on a user's behalf.
#
# It answers exactly two questions, because those are the two that ownership-verified registration
# rests on:
#
#   client = GithubApi.for(user)
#   client.repositories          # => Array<GithubApi::Repo>, what this user can pick from
#   client.repository("acme/x")  # => GithubApi::Repo,        what this user may do to that repo
#
# Both come back as `Repo`, which carries `admin?` — GitHub's own statement of the caller's
# permission level, and the thing verification tests. Nothing here decides who may register what;
# it reports what GitHub says and `GithubOwnership` decides. Keeping those apart is deliberate:
# the decision is then testable without a network, and the client has no policy in it to drift.
#
# ## Errors
#
# Everything that can go wrong with the network or with GitHub surfaces as a `GithubApi::Error` or
# one of its four subclasses. Callers rescue one class and never see a `Net::HTTP` or `JSON`
# exception. The subclasses exist because each means something different to a *user*:
#
#   Unauthorized  401 — the token is dead (revoked on GitHub, or expired). Re-authorize.
#   Forbidden     403 — the token is alive but may not do this: scope too narrow, SAML/SSO not
#                       authorized for the org, or rate limited.
#   NotFound      404 — no such repository *that this token can see*. GitHub deliberately answers
#                       404 rather than 403 for a private repository the caller cannot read, so
#                       this does NOT mean "does not exist" and must never be reported as such.
#   Unavailable         transport failure, timeout, 5xx, or a body that is not the JSON promised.
#
# ## Raw HTTP rather than Octokit
#
# Two endpoints, no pagination beyond `page=`, no webhooks, no GraphQL. Octokit would be a
# dependency, a version to track and a security surface for two GETs — and the ticket's one
# constraint on this choice (ownership is verified server-side) is unaffected either way.
#
# ## Test seam
#
# `GithubApi.factory` is the seam, in the shape and for the reason `EmbeddingGenerator.provider`
# documents: the suite installs a deterministic fake rather than stubbing HTTP, so no spec depends
# on the wire format and none of them reach the network.
#
#   GithubApi.factory = ->(token) { FakeGithub.new(...) }
#   GithubApi.factory = nil   # back to the real client
class GithubApi
  Error = Class.new(StandardError)
  Unauthorized = Class.new(Error)
  Forbidden = Class.new(Error)
  NotFound = Class.new(Error)
  Unavailable = Class.new(Error)

  API_ROOT = "https://api.github.com"

  # GitHub's maximum page size. Fewer, larger pages is strictly fewer round trips for the same
  # answer, and the registration page wants the whole list.
  PER_PAGE = 100

  # A ceiling on `repositories`, not a promise about anyone's account. Someone with more than this
  # many repositories would otherwise turn one page render into 40+ sequential GitHub round trips.
  # The list is a picker, and a picker that takes a minute to appear is not one; the *verification*
  # path does not read this list at all, so a repository past the cap is still registerable once
  # search reaches it. Kept visible rather than silent — `repositories` reports truncation.
  MAX_PAGES = 10

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # One repository as GitHub describes it to *this* caller. `admin` is the whole point: it is
  # GitHub's answer to "may this token administer this repository", which is the question
  # registration has to ask and could not ask before.
  #
  # `permissions` is present on every authenticated read of a repository (both endpoints below).
  # When it is absent the answer is `false`, never `nil` — an unknown permission level is not a
  # grant, and a nil flowing into a policy check is a bug waiting for a truthiness test.
  Repo = Data.define(:full_name, :private, :admin, :archived) do
    def admin? = admin
    def private? = private
    def archived? = archived

    def self.from(payload)
      permissions = payload["permissions"] || {}

      new(
        full_name: payload["full_name"].to_s,
        private: payload["private"] == true,
        admin: permissions["admin"] == true,
        archived: payload["archived"] == true
      )
    end
  end

  # What `repositories` returned, and whether that was all of it. A Data rather than an Array so a
  # caller cannot read a truncated list as a complete one — the picker says so out loud.
  Listing = Data.define(:repos, :truncated) do
    def truncated? = truncated
    def any? = repos.any?
  end

  class << self
    attr_writer :factory

    # Resolved on every call rather than memoized, so a reload in development never leaves a stale
    # autoloaded class behind — the same rule `EmbeddingGenerator.provider` states.
    def factory = @factory || ->(token) { new(token) }

    # A client bound to this user's stored token, or `nil` when there is none to bind.
    #
    # Returns nil rather than raising because "this user has not connected GitHub yet" is an
    # ordinary state of the world on every page that offers to connect it, not an exception. It is
    # also what a revoked-key rotation looks like from here (see `User#github_access_token`).
    def for(user)
      token = user&.github_access_token
      return nil if token.blank?

      factory.call(token)
    end
  end

  def initialize(access_token)
    @access_token = access_token
  end

  # Every repository this token can see that the user has some direct relationship with, newest
  # affiliation model first: repositories they own, repositories they collaborate on, and
  # repositories they reach through an organization. Sorted by full name so the picker is stable
  # between renders rather than reordered by GitHub's push activity.
  #
  # Returns a `Listing`, not an Array, so a caller cannot read a truncated list as a complete one.
  def repositories
    repos = []
    truncated = false

    (1..MAX_PAGES).each do |page|
      batch = get("/user/repos", affiliation: "owner,collaborator,organization_member",
                                sort: "full_name", direction: "asc",
                                per_page: PER_PAGE, page: page)
      repos.concat(Array(batch).map { |payload| Repo.from(payload) })

      break if Array(batch).length < PER_PAGE

      truncated = page == MAX_PAGES
    end

    Listing.new(repos: repos, truncated: truncated)
  end

  # One repository, with this caller's permissions on it. Raises `NotFound` when the token cannot
  # see it — which, per the note above, covers both "no such repository" and "private, and not
  # yours". Both are the same answer to the only question asked here.
  def repository(full_name)
    Repo.from(get("/repos/#{path_segment(full_name)}"))
  end

  private

  attr_reader :access_token

  def get(path, **query)
    uri = URI.parse("#{API_ROOT}#{path}")
    uri.query = URI.encode_www_form(query) if query.any?

    parse(perform(uri))
  end

  def perform(uri)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["User-Agent"] = "SpecGuard"

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                            open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.request(request)
    end
  rescue StandardError => e
    # Deliberately broad: Net::HTTP raises a dozen unrelated ancestors (Errno::*, OpenSSL,
    # Net::OpenTimeout, SocketError) and enumerating them is a list that goes stale silently.
    # Everything here means the same thing to a caller — GitHub could not be reached.
    raise Unavailable, "GitHub request failed: #{e.class}: #{e.message}"
  end

  def parse(response)
    case response
    when Net::HTTPSuccess then decode(response.body)
    when Net::HTTPUnauthorized then raise Unauthorized, "GitHub rejected the access token."
    when Net::HTTPForbidden then raise Forbidden, forbidden_message(response)
    when Net::HTTPNotFound then raise NotFound, "GitHub has no such repository visible to this token."
    else raise Unavailable, "GitHub responded #{response.code}."
    end
  end

  def decode(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError => e
    raise Unavailable, "GitHub returned a body that is not JSON: #{e.message}"
  end

  # 403 is GitHub's answer to several unrelated situations, and telling them apart matters to
  # whoever reads the flash: a rate limit clears on its own, an SSO block needs a click in the org,
  # and a narrow scope needs re-authorization.
  def forbidden_message(response)
    if response["x-ratelimit-remaining"] == "0"
      "GitHub rate limit reached; try again shortly."
    elsif response["x-github-sso"].present?
      "GitHub requires SSO authorization for that organization."
    else
      "GitHub refused the request; the granted access may be too narrow."
    end
  end

  # `org/repo` reaches a URL path. Each segment is escaped independently so a `/` inside one cannot
  # become a path separator — the value arrives from a form field, and the model's format
  # validation runs *after* this in `#update`'s case, not before.
  def path_segment(full_name)
    full_name.to_s.split("/", 2).map { |segment| ERB::Util.url_encode(segment) }.join("/")
  end
end
