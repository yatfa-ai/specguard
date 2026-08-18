# frozen_string_literal: true

# Deterministic stand-in for the GitHub REST API, installed for the whole suite (see the
# RSpec.configure block at the bottom). No spec reaches api.github.com, and — the part that changed
# with the GitHub App — no spec needs App credentials, a private key, or a minted token.
#
# Installed through `GithubApi.factory` — the public swap seam production code uses — rather than by
# stubbing HTTP or constants, the same discipline spec/support/embedding_generator.rb states in
# full. Nothing here knows the wire format, so a spec cannot pass because it agreed with the
# client's own idea of GitHub's JSON.
#
# `GithubApi.for_installation` resolves its credential lazily, so the fake never triggers a mint:
# the `InstallationCredential` it is handed is simply never asked for its token. That is what lets
# the suite run green with `SpecGuard::GithubApp` unconfigured, which is the state every developer
# machine and every CI run is in.
#
# ## The default is permissive, on purpose — but the LIST is the gate
#
# The suite's default is "the signed-in user has installed the App on `acme/billing-service` and
# `acme/checkout`". That keeps every pre-existing spec — which is about API keys, sharing, ingestion
# or a dashboard panel, and merely needs *a* registered repository — saying what it always said.
#
# What is NOT permissive any more, and could not be, is a name outside that list. Ownership is now
# membership of the installation, so verification is a set test over the listing rather than a
# per-name question the fake could answer optimistically. A spec that registers something else has
# to say so:
#
#   stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/payments")])
#
# That is a real improvement in what the suite proves: under the old permissive `repository`
# fallback every slug verified, which is exactly the world SPGD-354 removed and SPGD-424 replaced.
# Here the offered set and the registerable set are the same object, so a spec cannot register
# something the picker never offered.
#
# ## Failure is opt-in
#
#   stub_github(repos: [])                        # installed, nothing selected
#   stub_github(unauthorized: true)               # GitHub rejected the App's credentials
#   stub_github(unavailable: true)                # GitHub is down
#   stub_github(not_found: true)                  # this installation is gone (uninstalled)
#   stub_github(forbidden: :rate_limited)         # 403, and which of the two 403s it is
#   stub_github(truncated: true)                  # more repositories than one pass reads
#
# `forbidden:` takes a `GithubApi::Forbidden` reason (`:rate_limited`, `:refused`) rather than a
# boolean, because a rate limit clears by waiting and a refusal does not.
#
# ## `owner_type` defaults to "Organization"
#
# `github_repo` describes an ORGANIZATION repository unless told otherwise, because the shared
# fixtures are `acme/…` and because org repositories are what bulk registration groups
# (`GithubOrganizations`). A personal one says so:
#
#   github_repo("octocat/dotfiles", owner_type: "User")
class FakeGithubApi
  # `calls` is a log, not a mock expectation. Some specs need "GitHub was asked exactly once" or
  # "GitHub was not asked at all" — an unchanged rename must not cost a round trip — and a counter
  # answers that without a message expectation that also stubs the behaviour it is measuring.
  attr_reader :calls

  def initialize(repos: [], unauthorized: false, unavailable: false, not_found: false,
                 truncated: false, forbidden: nil)
    @repos = repos
    @unauthorized = unauthorized
    @unavailable = unavailable
    @not_found = not_found
    @truncated = truncated
    @forbidden = forbidden
    @calls = []
  end

  def repositories
    @calls << [:repositories]
    raise_configured_failure

    GithubApi::Listing.new(repos: @repos, truncated: @truncated)
  end

  # The single-repository read, which the real client answers from the installation and which
  # `InstallationRepositories` only reaches when the listing was incomplete. There is deliberately
  # no permissive fallback: an installation credential cannot see outside its own installation, so
  # a name that is not in `repos` is a `NotFound` here exactly as it would be from GitHub.
  def repository(full_name)
    @calls << [:repository, full_name]
    raise_configured_failure

    @repos.find { |repo| repo.full_name.casecmp?(full_name.to_s) } ||
      raise(GithubApi::NotFound, "no such repository in this installation")
  end

  def calls_to(method) = calls.count { |call| call.first == method }

  private

  def raise_configured_failure
    raise GithubApi::Unauthorized, "app credentials rejected" if @unauthorized
    raise GithubApi::Unavailable, "github is down" if @unavailable
    raise GithubApi::NotFound, "no such installation" if @not_found
    raise GithubApi::Forbidden.new("github refused", reason: @forbidden) if @forbidden
  end
end

module GithubApiHelpers
  DEFAULT_REPOS = %w[acme/billing-service acme/checkout].freeze

  # Installs a fake for the rest of the example and returns it, so a spec can assert on `calls`.
  def stub_github(**options)
    options[:repos] = DEFAULT_REPOS.map { |name| github_repo(name) } unless options.key?(:repos)

    FakeGithubApi.new(**options).tap { |fake| GithubApi.factory = ->(_credential) { fake } }
  end

  def github_repo(full_name, private: false, archived: false, owner_type: "Organization")
    GithubApi::Repo.new(full_name: full_name, private: private, archived: archived,
                        owner_type: owner_type)
  end

  # A signed-in user who has NOT installed the App — the state every user is in immediately after
  # signing in, before they first connect anything. The replacement for the OAuth era's
  # `revoke_github_repository_access`, and it is a plainer thing to say: there is no grant to narrow
  # or revoke any more, only an installation that is there or is not.
  def uninstall_github_app(user)
    user.github_installations.destroy_all
    user.reload
  end

  # A second installation for the same user, for the specs about merging across them.
  def add_github_installation(user, installation_id:, account_login: nil)
    GithubInstallation.record(user: user, installation_id: installation_id, account_login: account_login)
  end
end

RSpec.configure do |config|
  config.include GithubApiHelpers

  config.before { stub_github }
  config.after do
    GithubApi.factory = nil
    # The token cache is a plain constant on the class, so it outlives an example. Nothing in the
    # suite mints a token — the fake is installed before every example — but a spec that exercises
    # `GithubAppCredentials` directly would otherwise leave one behind for the next.
    GithubAppCredentials.reset!
  end
end
