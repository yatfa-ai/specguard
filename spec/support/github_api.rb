# frozen_string_literal: true

# Deterministic stand-in for the GitHub REST API, installed for the whole suite (see the
# RSpec.configure block at the bottom). No spec reaches api.github.com, and no spec needs App
# credentials or a real GitHub token.
#
# Installed through `GithubApi.factory` — the public swap seam production code uses — rather than by
# stubbing HTTP or constants, the same discipline spec/support/embedding_generator.rb states in
# full. Nothing here knows the wire format, so a spec cannot pass because it agreed with the
# client's own idea of GitHub's JSON.
#
# ## The default is permissive, on purpose — but the LIST is the gate
#
# The suite's default is "the signed-in user has installed the App on `acme/billing-service` and
# `acme/checkout`, and administers both". That keeps every pre-existing spec — which is about API
# keys, sharing, ingestion or a dashboard panel, and merely needs *a* registered repository —
# saying what it always said.
#
# What is NOT permissive is a name outside that list, or one in it the user does not administer.
# Registration takes both — the repository is in an installation AND GitHub reports this user as an
# administrator of it — so a spec that registers something else has to say so:
#
#   stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/payments")])
#
# and a spec about the organization member who can SEE a repository without administering it says
# that:
#
#   stub_github(repos: [github_repo("acme/billing", admin: false)])
#
# The offered set and the registerable set are the same object, so a spec cannot register something
# the picker never offered.
#
# ## Failure is opt-in
#
#   stub_github(repos: [])                        # installed, nothing this user can reach
#   stub_github(unauthorized: true)               # the user's token expired or was revoked
#   stub_github(unavailable: true)                # GitHub is down
#   stub_github(not_found: true)                  # this installation is gone, or unreachable by them
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
  #
  # `token` and `installation_id` are recorded because WHICH credential a read was made with is now
  # a security property rather than a detail: a spec can assert that the user's own token reached
  # GitHub, which is the whole of what stops one organization member reading another's repositories.
  attr_reader :calls, :token, :installation_id

  def initialize(repos: [], unauthorized: false, unavailable: false, not_found: false,
                 truncated: false, forbidden: nil, token: nil, installation_id: nil)
    @repos = repos
    @unauthorized = unauthorized
    @unavailable = unavailable
    @not_found = not_found
    @truncated = truncated
    @forbidden = forbidden
    @token = token
    @installation_id = installation_id
    @calls = []
  end

  def repositories
    @calls << [:repositories]
    raise_configured_failure

    GithubApi::Listing.new(repos: @repos, truncated: @truncated)
  end

  def calls_to(method) = calls.count { |call| call.first == method }

  # Records the credential this client was built with and returns self, so one fake can stand in
  # for every installation while still reporting WHICH credential reached it.
  def credentialed(token, installation_id)
    @token = token
    @installation_id = installation_id
    self
  end

  private

  def raise_configured_failure
    raise GithubApi::Unauthorized, "github rejected the token" if @unauthorized
    raise GithubApi::Unavailable, "github is down" if @unavailable
    raise GithubApi::NotFound, "no such installation for this user" if @not_found
    raise GithubApi::Forbidden.new("github refused", reason: @forbidden) if @forbidden
  end
end

module GithubApiHelpers
  DEFAULT_REPOS = %w[acme/billing-service acme/checkout].freeze

  # Installs a fake for the rest of the example and returns it, so a spec can assert on `calls`.
  #
  # One fake serves every installation, and it records the credential and installation id it was
  # last handed — which is what lets a spec check that reads are made AS THE USER rather than as the
  # App. `stub_github_per_installation` is the shape for specs that need a different answer per
  # installation.
  def stub_github(**options)
    options[:repos] = DEFAULT_REPOS.map { |name| github_repo(name) } unless options.key?(:repos)

    FakeGithubApi.new(**options).tap do |fake|
      GithubApi.factory = ->(token, installation_id) { fake.credentialed(token, installation_id) }
    end
  end

  # A different fake per installation id, for the specs about merging and partial failure. The block
  # receives the installation id and returns a `FakeGithubApi`; the user's token is passed through
  # to it so those specs can assert on the credential too.
  def stub_github_per_installation(&block)
    GithubApi.factory = ->(token, installation_id) { block.call(installation_id).credentialed(token, installation_id) }
  end

  # `admin` defaults to TRUE so that every spec written before administration was checked keeps
  # describing a user who can register what they can see. A spec about the organization member who
  # cannot says `admin: false`, which is the whole of the distinction this fixture carries.
  def github_repo(full_name, private: false, archived: false, owner_type: "Organization", admin: true)
    GithubApi::Repo.new(full_name: full_name, private: private, archived: archived,
                        owner_type: owner_type, admin: admin)
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
  config.after { GithubApi.factory = nil }
end
