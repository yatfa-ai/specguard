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
#   Forbidden     403 — the token is alive but may not do this. Carries a `reason` (see below),
#                       because the three things GitHub answers 403 for have three unrelated fixes.
#   NotFound      404 — no such repository *that this token can see*. GitHub deliberately answers
#                       404 rather than 403 for a private repository the caller cannot read, so
#                       this does NOT mean "does not exist" and must never be reported as such.
#   Unavailable         transport failure, timeout, 5xx, or a body that is not the JSON promised.
#
# `Forbidden#reason` is a symbol rather than prose because a caller has to *branch* on it, not print
# it. An SSO block and a rate limit are both 403 and they are opposites: one clears itself in an
# hour, the other never clears until a human clicks approve in the organization. Collapsing them
# into one "try again shortly" is how a user ends up retrying forever — see GithubOwnership, which
# maps each reason to the fix that actually resolves it.
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
  NotFound = Class.new(Error)
  Unavailable = Class.new(Error)

  # 403, with which of the three unrelated 403s it was. `reason` is one of:
  #
  #   :rate_limited       GitHub's hourly budget for this token is spent. Genuinely transient —
  #                       this is the only 403 for which "try again shortly" is true.
  #   :sso_required       the repository belongs to an organization enforcing SAML SSO that this
  #                       token has not been authorized for. Never clears on its own: somebody has
  #                       to authorize the token for that organization on GitHub.
  #   :insufficient_scope the grant is too narrow to answer the question. Fixed by re-authorizing.
  #
  # Defaults to `:insufficient_scope` because it is the only one of the three that a caller can
  # act on blindly without misleading anybody: it offers a re-authorize the user may not need,
  # rather than a wait that will never end.
  class Forbidden < Error
    attr_reader :reason

    def initialize(message = nil, reason: :insufficient_scope)
      super(message)
      @reason = reason
    end
  end

  API_ROOT = "https://api.github.com"

  # GitHub's maximum page size. Fewer, larger pages is strictly fewer round trips for the same
  # answer, and the registration page wants the whole list.
  PER_PAGE = 100

  # A ceiling on `repositories`, not a promise about anyone's account. Someone with more than this
  # many repositories would otherwise turn one page render into 40+ sequential GitHub round trips.
  # The list is a picker, and a picker that takes a minute to appear is not one.
  #
  # Note what this cap now costs, because it changed meaning in this slice: the picker is the only
  # way to submit a repository, and the type-to-narrow box searches the options already fetched
  # rather than asking GitHub. So a repository past the cap is currently NOT registerable through
  # any UI path. Back when the field was free text, the cap only affected convenience. Fixing it
  # properly means a GitHub-side search endpoint behind the query box; until then this is a real,
  # if rare, wall — and `repositories` reports truncation so the picker can say so out loud rather
  # than appear complete.
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
  #
  # `owner_type` is GitHub's own `owner.type` — `"Organization"` or `"User"` — and it is the one
  # field that distinguishes an organization's repository from a personal one. Bulk registration
  # groups the listing by owner and offers the organizations (see `GithubOrganizations`), and the
  # owner *segment* of `full_name` cannot answer that question: `acme/x` is the same string whether
  # `acme` is an org or a person who happens to be called that. Defaulted to `nil` — "GitHub did
  # not say" — because both `Repo.new` call sites outside this file are tests and a required field
  # would make every one of them describe an owner it does not care about; `organization?` reads a
  # nil as "not an organization", which withholds rather than invents.
  Repo = Data.define(:full_name, :private, :admin, :archived, :owner_type) do
    def initialize(owner_type: nil, **) = super

    def admin? = admin
    def private? = private
    def archived? = archived
    def organization? = owner_type == "Organization"

    # The owner segment of `full_name` — the GitHub account the repository lives under. A
    # *namespace*, not a SpecGuard user and not necessarily an organization; see `organization?`.
    def owner = full_name.to_s.split("/").first.to_s

    def self.from(payload)
      permissions = payload["permissions"] || {}

      new(
        full_name: payload["full_name"].to_s,
        private: payload["private"] == true,
        admin: permissions["admin"] == true,
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
  #
  # == This is also how an organization's repositories are enumerated
  #
  # `organization_member` is the affiliation that carries them, and every row arrives with the
  # caller's own `permissions.admin` and its `owner.type` already on it. So bulk registration
  # groups THIS listing by owner rather than calling `GET /user/orgs` + `GET /orgs/:org/repos`
  # (`GithubOrganizations`), and three things follow that are worth stating, because the obvious
  # reading is that a dedicated org endpoint would be more direct:
  #
  #   - No `read:org`. The org endpoints need a scope the `repo` grant does not include, so adding
  #     them would mean every user who already authorized in SPGD-354 has a stored token that
  #     cannot enumerate an org until they re-authorize. Bulk registration would be broken for
  #     exactly the users most likely to want it.
  #   - One round trip for every org, not one per org plus a page walk inside each. A batch is
  #     already N saves; making its enumeration O(orgs × pages) buys nothing.
  #   - The set is the RIGHT one rather than a superset. `/orgs/:org/repos` lists repositories the
  #     caller may not touch; only a repository the caller can see and administer is registerable,
  #     and that is precisely what this returns.
  #
  # What it costs is stated where it bites: `MAX_PAGES` bounds the whole listing, so an
  # organization's repositories can be cut off by a *global* cap rather than a per-org one, and
  # `truncated` is how a caller learns to say so instead of presenting a partial org as complete.
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
    when Net::HTTPForbidden then raise forbidden_error(response)
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
  # whoever has to fix it: a rate limit clears on its own, an SSO block needs a click in the org,
  # and a narrow scope needs re-authorization. The reason travels on the exception so the decision
  # is made from a symbol; the message is for the log.
  #
  # Read in this order deliberately. GitHub sends `X-GitHub-SSO` on a *rate-limited* response to an
  # SSO org as readily as on an authorization failure, so checking SSO first would report an
  # hour-long wait as a permanent org-approval problem. Exhaustion is the narrower, more certain
  # signal, so it wins.
  def forbidden_error(response)
    if response["x-ratelimit-remaining"] == "0"
      Forbidden.new("GitHub rate limit reached; try again shortly.", reason: :rate_limited)
    elsif response["x-github-sso"].present?
      Forbidden.new("GitHub requires SSO authorization for that organization.", reason: :sso_required)
    else
      Forbidden.new("GitHub refused the request; the granted access may be too narrow.",
                    reason: :insufficient_scope)
    end
  end

  # `org/repo` reaches a URL path. Each segment is escaped independently so a `/` inside one cannot
  # become a path separator — the value arrives from a form field, and the model's format
  # validation runs *after* this in `#update`'s case, not before.
  def path_segment(full_name)
    full_name.to_s.split("/", 2).map { |segment| ERB::Util.url_encode(segment) }.join("/")
  end
end
