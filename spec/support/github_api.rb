# frozen_string_literal: true

# Deterministic stand-in for the GitHub REST API, installed for the whole suite (see the
# RSpec.configure block at the bottom). No spec reaches api.github.com and no spec needs a token.
#
# Installed through `GithubApi.factory` — the public swap seam production code would use — rather
# than by stubbing HTTP or constants, the same discipline spec/support/embedding_generator.rb
# states in full. Nothing here knows the wire format, so a spec cannot pass because it agreed with
# the client's own idea of GitHub's JSON.
#
# ## The default is permissive, on purpose
#
# The suite's default is "the signed-in user administers every repository they name". That keeps
# every pre-existing spec — which is about API keys, sharing, ingestion or a dashboard panel, and
# merely needs *a* registered repository — saying what it always said, without each one having to
# describe a GitHub account it does not care about.
#
# It also means a spec about *refusal* has to say so out loud:
#
#   stub_github(repos: [github_repo("acme/billing-service", admin: false)])
#   stub_github(repos: [], unauthorized: true)
#   stub_github(repos: [github_repo("acme/billing-service")], strict: true)  # 404 anything else
#
# `strict: true` is the switch that makes the fake behave like GitHub does for a stranger's
# repository: anything not in `repos` is `NotFound`. Use it for anything asserting the squatting
# gap is closed — under the permissive default every slug verifies, which is exactly the world
# this ticket removed.
class FakeGithubApi
  # `calls` is a log, not a mock expectation. Some specs need "GitHub was asked exactly once" or
  # "GitHub was not asked at all" — an unchanged rename must not cost a round trip — and a counter
  # answers that without a message expectation that also stubs the behaviour it is measuring.
  attr_reader :calls

  def initialize(repos: [], strict: false, unauthorized: false, unavailable: false, truncated: false)
    @repos = repos
    @strict = strict
    @unauthorized = unauthorized
    @unavailable = unavailable
    @truncated = truncated
    @calls = []
  end

  def repositories
    @calls << [:repositories]
    raise_configured_failure

    GithubApi::Listing.new(repos: @repos, truncated: @truncated)
  end

  def repository(full_name)
    @calls << [:repository, full_name]
    raise_configured_failure

    found = @repos.find { |repo| repo.full_name.casecmp?(full_name.to_s) }
    return found if found
    raise GithubApi::NotFound, "no such repository" if @strict

    # The permissive default: a repository nobody described is one the caller administers.
    GithubApi::Repo.new(full_name: full_name.to_s, private: false, admin: true, archived: false)
  end

  def calls_to(method) = calls.count { |call| call.first == method }

  private

  def raise_configured_failure
    raise GithubApi::Unauthorized, "token rejected" if @unauthorized
    raise GithubApi::Unavailable, "github is down" if @unavailable
  end
end

module GithubApiHelpers
  DEFAULT_REPOS = %w[acme/billing-service acme/checkout].freeze

  # Installs a fake for the rest of the example and returns it, so a spec can assert on `calls`.
  def stub_github(**options)
    options[:repos] = DEFAULT_REPOS.map { |name| github_repo(name) } unless options.key?(:repos)

    FakeGithubApi.new(**options).tap { |fake| GithubApi.factory = ->(_token) { fake } }
  end

  def github_repo(full_name, admin: true, private: false, archived: false)
    GithubApi::Repo.new(full_name: full_name, private: private, admin: admin, archived: archived)
  end

  # A signed-in user who has *not* taken the second authorization step — the state every user is in
  # immediately after signing in, before they first register anything.
  def revoke_github_repository_access(user)
    user.update!(github_access_token: nil, github_token_scopes: nil)
  end

  # Granted the identity scopes and nothing more: a live token that cannot read repositories. The
  # distinction matters — `GithubOwnership` must answer `:not_connected` from the stored grant
  # without a round trip, rather than discovering it from a 403.
  def narrow_github_scope(user)
    user.update!(github_token_scopes: SpecGuard::GithubOauth::SIGN_IN_SCOPE)
  end
end

RSpec.configure do |config|
  config.include GithubApiHelpers

  config.before { stub_github }
  config.after { GithubApi.factory = nil }
end
