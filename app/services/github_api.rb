# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# The GitHub REST client — the app's only way to ask GitHub a question.
#
# It authenticates as a PERSON, with that person's own short-lived user-to-server token, and answers
# exactly one question:
#
#   client = GithubApi.for_user(token, installation)
#   client.repositories   # => GithubApi::Listing — which repositories in that installation THIS
#                         #    user can reach, and what their own access to each one is
#
# ## Why the user's credential and not the App's
#
# An installation access token speaks for the App. It can list everything the installation reaches,
# and it says nothing whatever about the person asking — so a plain organization member, who can
# SEE their organization's installation but administers none of it, would read back every
# repository in it. That is exactly the squatting gap this slice exists to close, so the credential
# that cannot distinguish those two people is not used at all: SpecGuard holds no App private key
# and mints no installation token.
#
# `GET /user/installations/:id/repositories` asks the question that actually matters, and asks it
# of a credential that can only answer for one person. It is installation-scoped, so a repository
# nobody handed to SpecGuard is not in it; and it reports the caller's OWN permissions on each
# repository, which is what `InstallationRepositories` reads to require administration rather than
# mere visibility. Neither half is sufficient alone and both are enforced.
#
# Nothing here decides who may register what — the client reports what GitHub said and
# `InstallationRepositories` holds the policy. Keeping the decision out of the client is deliberate:
# it is then testable without a network, and the client has no policy in it to drift.
#
# ## The credential
#
# A user-to-server token, obtained from the `code` GitHub sends back from the install or
# authorization flow (`GithubAppUserAuthorization`), held for the browser session and never written
# to the database. Its reach is the App's declared permissions (Metadata: read-only) intersected
# with the user's own access — it cannot write anything and cannot read code. It is emphatically not
# the OAuth `repo` scope this slice removed.
#
# ## Errors
#
# Everything that can go wrong with the network or with GitHub surfaces as a `GithubApi::Error` or
# one of its four subclasses. Callers rescue one class and never see a `Net::HTTP` or `JSON`
# exception. The subclasses exist because each means something different to a *user*:
#
#   Unauthorized  401 — GitHub rejected the token. It has expired or been revoked, and the fix is
#                       to authorize again, which is a thing the user can actually do.
#   Forbidden     403 — the credential is valid but may not do this. Carries a `reason`; see below.
#   NotFound      404 — no such installation *for this user*. GitHub answers 404 rather than 403 for
#                       anything the credential cannot see, so this does NOT mean "does not exist"
#                       and must never be reported as such. It is also what an uninstalled
#                       installation looks like.
#   Unavailable         transport failure, timeout, 5xx, or a body that is not the JSON promised.
#
# ## Raw HTTP rather than Octokit
#
# One endpoint, no GraphQL, and no credential machinery to inherit. Octokit would be a dependency, a
# version to track and a security surface for a single GET.
#
# ## Test seam
#
# `GithubApi.factory` is the seam, in the shape and for the reason `EmbeddingGenerator.provider`
# documents: the suite installs a deterministic fake rather than stubbing HTTP, so no spec depends
# on the wire format, none of them reach the network, and none of them needs a GitHub token.
#
#   GithubApi.factory = ->(*) { FakeGithub.new(...) }
#   GithubApi.factory = nil   # back to the real client
class GithubApi
  Error = Class.new(StandardError)
  Unauthorized = Class.new(Error)
  NotFound = Class.new(Error)
  Unavailable = Class.new(Error)

  # Raised when the SpecGuard GitHub App has no credentials on this instance. An `Unavailable`
  # rather than a class of its own so every caller's existing rescue already fails CLOSED on it: an
  # unconfigured instance registers nothing rather than everything. It lives here, with the rest of
  # the family, because `config/initializers/github_app.rb` is loaded before the autoloader can
  # resolve anything and cannot define a subclass of a class in `app/`.
  NotConfigured = Class.new(Unavailable)

  # 403, with which of the two reachable 403s it was. `reason` is one of:
  #
  #   :rate_limited  GitHub's hourly budget for this credential is spent. Genuinely transient —
  #                  this is the one 403 for which "try again shortly" is true.
  #   :refused       GitHub declined for any other reason. Not actionable by the user, and not
  #                  waitable either, so it is reported rather than dressed up as a retry.
  #
  # The `:sso_required` and `:insufficient_scope` reasons this used to distinguish are gone with the
  # `repo` grant they were written for. A user-to-server token for a GitHub App carries no scopes to
  # be insufficient, and it reaches an organization by way of that organization's own installation
  # rather than by a SAML authorization of its own. Neither branch could be triggered any more, and
  # a branch that cannot be reached is a branch nobody can find out is wrong.
  class Forbidden < Error
    attr_reader :reason

    def initialize(message = nil, reason: :refused)
      super(message)
      @reason = reason
    end
  end

  API_ROOT = "https://api.github.com"

  # GitHub's maximum page size. Fewer, larger pages is strictly fewer round trips for the same
  # answer, and the registration page wants the whole list.
  PER_PAGE = 100

  # A ceiling on `repositories`, not a promise about anyone's installation. Someone who reached more
  # than this many repositories through one installation would otherwise turn one page render into
  # 10+ sequential GitHub round trips. The list is a picker, and a picker that takes a minute to
  # appear is not one.
  #
  # It bites less than it did under the OAuth listing, which enumerated every repository the user
  # could reach: this is bounded twice over, by what somebody deliberately selected for the
  # installation and by what this user can see of it. It still bites, so `repositories` reports
  # truncation and `InstallationRepositories` refuses rather than guessing when it is set.
  MAX_PAGES = 10

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # One repository as GitHub describes it TO THIS USER.
  #
  # `admin` is the user's own permission on the repository, off GitHub's `permissions` hash — and it
  # is back, having briefly been removed along with the OAuth grant that used to buy it. Removing it
  # was the error this replaces: presence in an installation proves somebody with administrative
  # rights handed the repository to SpecGuard, not that the person reading the list is that
  # somebody. Any organization member can see their organization's installation.
  #
  # What changed is not that the admin bar came back but what it costs: it used to be read off
  # `GET /repos/:owner/:repo` over `repo` — GitHub's full control of private repositories, read and
  # write, across everything the user could reach — and it now rides along on a listing the App's
  # Metadata: read-only grant already answers.
  #
  # It defaults to FALSE, which is the fail-closed default and matters: a payload with no
  # `permissions` hash (an older API version, a shape that changed) reads as "not an administrator"
  # and the repository is not offered, rather than reading as one and being offered to everybody.
  #
  # `owner_type` is GitHub's own `owner.type` — `"Organization"` or `"User"` — and it is the one
  # field that distinguishes an organization's repository from a personal one. Bulk registration
  # groups the listing by owner and offers the organizations (see `GithubOrganizations`), and the
  # owner *segment* of `full_name` cannot answer that question: `acme/x` is the same string whether
  # `acme` is an org or a person who happens to be called that. Defaulted to `nil` — "GitHub did
  # not say" — because `Repo.new` call sites outside this file are tests and a required field would
  # make every one of them describe an owner it does not care about; `organization?` reads a nil as
  # "not an organization", which withholds rather than invents.
  Repo = Data.define(:full_name, :private, :archived, :owner_type, :admin) do
    def initialize(owner_type: nil, admin: false, **) = super

    def private? = private
    def archived? = archived
    def admin? = admin
    def organization? = owner_type == "Organization"

    # The other side GitHub reports, and NOT the negation of `organization?`. Both are positive
    # claims about what GitHub actually said, so a repository whose `owner_type` is nil answers
    # false to BOTH rather than being counted as personal by default — the same withhold-rather-
    # than-invent reflex `organization?` applies in the other direction. Callers that need to say
    # which kind of namespace something is must therefore ask, and get "GitHub did not say" as a
    # third answer instead of a guess.
    def personal? = owner_type == "User"

    # The owner segment of `full_name` — the GitHub account the repository lives under. A
    # *namespace*, not a SpecGuard user and not necessarily an organization; see `organization?`.
    def owner = full_name.to_s.split("/").first.to_s

    def self.from(payload)
      new(
        full_name: payload["full_name"].to_s,
        private: payload["private"] == true,
        archived: payload["archived"] == true,
        owner_type: payload.dig("owner", "type"),
        admin: payload.dig("permissions", "admin") == true
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
    def factory = @factory || ->(token, installation_id) { new(token, installation_id) }

    # A client that reads one installation AS THIS USER, or `nil` when there is nothing to read
    # with.
    #
    # Returns nil rather than raising because both of its reasons are ordinary states of the world
    # on a page that offers to fix them: the user has not installed the App, or this session holds
    # no user credential and one must be fetched. Neither is an exception.
    #
    # Takes a `GithubInstallation` or a bare id, so a caller that has only the number does not have
    # to load a row to use it.
    def for_user(token, installation)
      return nil if token.blank?

      id = installation.respond_to?(:installation_id) ? installation.installation_id : installation
      id = id.to_i
      return nil unless id.positive?

      factory.call(token, id)
    end
  end

  def initialize(token, installation_id)
    @token = token
    @installation_id = installation_id
  end

  # Which repositories in this installation the authenticated USER can reach, with their own access
  # to each one. Sorted by full name so the picker is stable between renders rather than reordered
  # by GitHub's push activity.
  #
  # Returns a `Listing`, not an Array, so a caller cannot read a truncated list as a complete one.
  #
  # GitHub sorts this endpoint by nothing in particular and offers no `sort` parameter, so the
  # ordering is applied here. That also keeps it identical to the order a caller sees after
  # `InstallationRepositories` merges several installations together.
  def repositories
    repos = []
    truncated = false

    (1..MAX_PAGES).each do |page|
      batch = page_of_repositories(page)
      repos.concat(batch.map { |payload| Repo.from(payload) })

      break if batch.length < PER_PAGE

      truncated = page == MAX_PAGES
    end

    Listing.new(repos: repos.sort_by { |repo| repo.full_name.downcase }, truncated: truncated)
  end

  private

  attr_reader :token, :installation_id

  # `GET /user/installations/:id/repositories` answers with an OBJECT —
  # `{total_count:, repository_selection:, repositories: […]}` — where the user-token endpoint this
  # replaces answered with a bare array. Unwrapped here rather than at the call site so
  # `repositories` still reads as a page walk, and defaulted to `[]` so a body of an unexpected
  # shape ends the walk instead of raising a NoMethodError several frames up.
  def page_of_repositories(page)
    payload = get("/user/installations/#{installation_id}/repositories", per_page: PER_PAGE, page: page)

    # Defaulted to `[]` so a body of an unexpected shape ends the walk, and filtered to Hashes so a
    # body of the RIGHT shape carrying the wrong contents — `{"repositories": [1, 2]}` — ends it too
    # rather than raising a NoMethodError out of `Repo.from`. `sources` promises never to raise, and
    # that promise cannot rest on GitHub's JSON being well-formed.
    Array(payload.is_a?(Hash) ? payload["repositories"] : payload).grep(Hash)
  end

  def get(path, **query)
    uri = URI.parse("#{API_ROOT}#{path}")
    uri.query = URI.encode_www_form(query) if query.any?

    parse(perform(uri))
  end

  def perform(uri)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"
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
    when Net::HTTPUnauthorized then raise Unauthorized, "GitHub rejected the authorization."
    when Net::HTTPForbidden then raise forbidden_error(response)
    when Net::HTTPNotFound then raise NotFound, "GitHub has no such installation for this user."
    else raise Unavailable, "GitHub responded #{response.code}."
    end
  end

  # A bare JSON scalar — `null`, `"maintenance"`, `7` — parses without error and is not a document.
  # Read as an empty object rather than handed on, so a caller's `dig` does not become the first
  # thing to notice.
  def decode(body)
    parsed = JSON.parse(body.to_s)
    parsed.is_a?(Hash) || parsed.is_a?(Array) ? parsed : {}
  rescue JSON::ParserError => e
    raise Unavailable, "GitHub returned a body that is not JSON: #{e.message}"
  end

  # Rate limiting is the one 403 worth telling apart, because it is the only one that clears by
  # waiting. Everything else GitHub refuses for is reported as a refusal rather than as a retry the
  # user would perform forever.
  def forbidden_error(response)
    if response["x-ratelimit-remaining"] == "0"
      Forbidden.new("GitHub rate limit reached; try again shortly.", reason: :rate_limited)
    else
      Forbidden.new("GitHub refused the request.", reason: :refused)
    end
  end
end
