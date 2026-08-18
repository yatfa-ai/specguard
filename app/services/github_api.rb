# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# The GitHub REST client — the app's only way to ask GitHub a question.
#
# It authenticates as a GitHub App *installation* and answers exactly two questions, because those
# are the two that installation-backed registration rests on:
#
#   client = GithubApi.for_installation(installation)
#   client.repositories          # => GithubApi::Listing, what this installation covers
#   client.repository("acme/x")  # => GithubApi::Repo,    is that one of them (404 when it is not)
#
# Nothing here reads a permission level, and nothing here decides who may register what. The
# question "may this user register this repository" is answered by the repository being IN the
# installation at all — only an administrator of a repository can install an App on it — and
# `InstallationRepositories` is where that is decided. Keeping the decision out of the client is
# deliberate: it is then testable without a network, and the client has no policy in it to drift.
#
# ## The credential
#
# An installation access token, minted on demand from the App's private key and never persisted
# (`GithubAppCredentials`). It is resolved LAZILY — on the first request the client actually makes —
# so a page that renders without asking GitHub anything never mints one, and the swap seam below
# never needs an App private key to stand in for this.
#
# ## Errors
#
# Everything that can go wrong with the network or with GitHub surfaces as a `GithubApi::Error` or
# one of its four subclasses. Callers rescue one class and never see a `Net::HTTP` or `JSON`
# exception. The subclasses exist because each means something different to a *user*:
#
#   Unauthorized  401 — GitHub rejected the App's own credentials. Unlike the user token this
#                       replaced, that is an operator's problem (wrong App id or private key), not
#                       something the user can fix by re-authorizing.
#   Forbidden     403 — the credential is valid but may not do this. Carries a `reason`; see below.
#   NotFound      404 — no such repository *in this installation*. GitHub answers 404 rather than
#                       403 for anything the credential cannot see, so this does NOT mean "does not
#                       exist" and must never be reported as such. It is also what an uninstalled
#                       installation looks like.
#   Unavailable         transport failure, timeout, 5xx, or a body that is not the JSON promised.
#
# ## Raw HTTP rather than Octokit
#
# Two endpoints, no GraphQL, and — since the credential is minted by `GithubAppCredentials` rather
# than by a gem — nothing Octokit would be carrying the weight of. It would be a dependency, a
# version to track and a security surface for two GETs.
#
# ## Test seam
#
# `GithubApi.factory` is the seam, in the shape and for the reason `EmbeddingGenerator.provider`
# documents: the suite installs a deterministic fake rather than stubbing HTTP, so no spec depends
# on the wire format, none of them reach the network, and none of them needs App credentials.
#
#   GithubApi.factory = ->(credential) { FakeGithub.new(...) }
#   GithubApi.factory = nil   # back to the real client
class GithubApi
  Error = Class.new(StandardError)
  Unauthorized = Class.new(Error)
  NotFound = Class.new(Error)
  Unavailable = Class.new(Error)

  # 403, with which of the two reachable 403s it was. `reason` is one of:
  #
  #   :rate_limited  GitHub's hourly budget for this installation is spent. Genuinely transient —
  #                  this is the one 403 for which "try again shortly" is true.
  #   :refused       GitHub declined for any other reason. Not actionable by the user, and not
  #                  waitable either, so it is reported rather than dressed up as a retry.
  #
  # The `:sso_required` and `:insufficient_scope` reasons this used to distinguish are gone with the
  # user token they were written for. SAML SSO authorization is a property of a *user* token — an
  # installation is authorized by the organization that installed it — and a scope is not something
  # an installation has. Neither branch could be triggered any more, and a branch that cannot be
  # reached is a branch nobody can find out is wrong.
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

  # A ceiling on `repositories`, not a promise about anyone's installation. Someone who selected
  # more than this many repositories would otherwise turn one page render into 10+ sequential
  # GitHub round trips. The list is a picker, and a picker that takes a minute to appear is not one.
  #
  # It bites less than it did under the OAuth listing, which enumerated every repository the user
  # could reach: an installation contains only what somebody deliberately selected. It still bites,
  # so `repositories` reports truncation and `InstallationRepositories` asks GitHub about a name
  # individually rather than refusing it for a property of our own page walk.
  MAX_PAGES = 10

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # One repository as GitHub describes it to this installation.
  #
  # There is no `admin` field, and its absence is the point of this slice: the permission level was
  # read to decide whether a user could register a repository, and that question is now settled by
  # the repository being in the installation at all. A `Repo` that reaches a caller is registerable.
  #
  # `owner_type` is GitHub's own `owner.type` — `"Organization"` or `"User"` — and it is the one
  # field that distinguishes an organization's repository from a personal one. Bulk registration
  # groups the listing by owner and offers the organizations (see `GithubOrganizations`), and the
  # owner *segment* of `full_name` cannot answer that question: `acme/x` is the same string whether
  # `acme` is an org or a person who happens to be called that. Defaulted to `nil` — "GitHub did
  # not say" — because `Repo.new` call sites outside this file are tests and a required field would
  # make every one of them describe an owner it does not care about; `organization?` reads a nil as
  # "not an organization", which withholds rather than invents.
  Repo = Data.define(:full_name, :private, :archived, :owner_type) do
    def initialize(owner_type: nil, **) = super

    def private? = private
    def archived? = archived
    def organization? = owner_type == "Organization"

    # The owner segment of `full_name` — the GitHub account the repository lives under. A
    # *namespace*, not a SpecGuard user and not necessarily an organization; see `organization?`.
    def owner = full_name.to_s.split("/").first.to_s

    def self.from(payload)
      new(
        full_name: payload["full_name"].to_s,
        private: payload["private"] == true,
        archived: payload["archived"] == true,
        owner_type: payload.dig("owner", "type")
      )
    end
  end

  # What `repositories` returned, and whether that was all of it. A Data rather than an Array so a
  # caller cannot read a truncated list as a complete one — the picker says so out loud.
  Listing = Data.define(:repos, :truncated) do
    def truncated? = truncated
    def any? = repos.any?
  end

  # Resolves an installation access token the first time the client actually needs one, and reuses
  # it for the rest of the client's life.
  #
  # Lazy rather than eager because a controller builds a client on paths that may never call
  # GitHub, and minting is a round trip. Held per client rather than looked up per request so a
  # listing that walks ten pages mints once.
  class InstallationCredential
    attr_reader :installation_id

    def initialize(installation_id)
      @installation_id = installation_id
    end

    def token = @token ||= GithubAppCredentials.installation_token(installation_id)
  end

  class << self
    attr_writer :factory

    # Resolved on every call rather than memoized, so a reload in development never leaves a stale
    # autoloaded class behind — the same rule `EmbeddingGenerator.provider` states.
    def factory = @factory || ->(credential) { new(credential) }

    # A client authenticated as this installation, or `nil` when there is none to authenticate as.
    #
    # Returns nil rather than raising because "this user has not installed the App yet" is an
    # ordinary state of the world on every page that offers to install it, not an exception.
    #
    # Takes a `GithubInstallation` or a bare id, so a caller that has only the number — a callback
    # confirming what it was just handed — does not have to load a row to use it.
    def for_installation(installation)
      id = installation.respond_to?(:installation_id) ? installation.installation_id : installation
      id = id.to_i
      return nil unless id.positive?

      factory.call(InstallationCredential.new(id))
    end
  end

  # Takes a credential object (`InstallationCredential`) or a bare token String. The String form is
  # for specs and the console; nothing on a request path uses it.
  def initialize(credential)
    @credential = credential
  end

  # Every repository in this installation — which is to say, exactly the ones somebody who
  # administers them chose to give SpecGuard. Sorted by full name so the picker is stable between
  # renders rather than reordered by GitHub's push activity.
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

  # One repository, when this installation covers it. Raises `NotFound` when it does not — which,
  # per the note above, covers "no such repository", "private and not shared with this App", and
  # "not selected in this installation" alike. All three are the same answer to the only question
  # asked here, and none of them is a registration.
  def repository(full_name)
    Repo.from(get("/repos/#{path_segment(full_name)}"))
  end

  private

  attr_reader :credential

  def access_token = credential.respond_to?(:token) ? credential.token : credential

  # `GET /installation/repositories` answers with an OBJECT — `{total_count:, repositories: […]}` —
  # where the user-token endpoint this replaces answered with a bare array. Unwrapped here rather
  # than at the call site so `repositories` still reads as a page walk, and defaulted to `[]` so a
  # body of an unexpected shape ends the walk instead of raising a NoMethodError several frames up.
  def page_of_repositories(page)
    payload = get("/installation/repositories", per_page: PER_PAGE, page: page)

    Array(payload.is_a?(Hash) ? payload["repositories"] : payload)
  end

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
  rescue GithubApi::Error
    # `access_token` is resolved inside this block and mints through `GithubAppCredentials`, which
    # raises this family. Without this the broad rescue below would relabel "the App is not
    # configured" or "that installation is gone" as "GitHub could not be reached".
    raise
  rescue StandardError => e
    # Deliberately broad: Net::HTTP raises a dozen unrelated ancestors (Errno::*, OpenSSL,
    # Net::OpenTimeout, SocketError) and enumerating them is a list that goes stale silently.
    # Everything here means the same thing to a caller — GitHub could not be reached.
    raise Unavailable, "GitHub request failed: #{e.class}: #{e.message}"
  end

  def parse(response)
    case response
    when Net::HTTPSuccess then decode(response.body)
    when Net::HTTPUnauthorized then raise Unauthorized, "GitHub rejected the SpecGuard App credentials."
    when Net::HTTPForbidden then raise forbidden_error(response)
    when Net::HTTPNotFound then raise NotFound, "GitHub has no such repository in this installation."
    else raise Unavailable, "GitHub responded #{response.code}."
    end
  end

  def decode(body)
    JSON.parse(body.to_s)
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

  # `org/repo` reaches a URL path. Each segment is escaped independently so a `/` inside one cannot
  # become a path separator — the value arrives from a form field, and the model's format
  # validation runs *after* this in `#update`'s case, not before.
  def path_segment(full_name)
    full_name.to_s.split("/", 2).map { |segment| ERB::Util.url_encode(segment) }.join("/")
  end
end
