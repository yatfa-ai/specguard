# frozen_string_literal: true

# WHETHER ANYTHING HAS CONNECTED TO A REPOSITORY, answered once — the three non-error branches of
# the repository page's connection indicator (`repositories/_connection_indicator.html.erb`) and
# the `credential_health.connection` block of the overview API, both read off this object so the
# console and the API cannot disagree about the same repository.
#
# == The states
#
# * `connected`      — some live key has authenticated with a token it still carries
#                      ({#last_live_request_at} present).
# * `rotated_unused` — something authenticated, but every token that did has since been rotated
#                      away ({#last_request_at} present, {#last_live_request_at} blank): CI is
#                      presenting a credential that no longer exists.
# * `not_connected`  — no live key has authenticated.
#
# The indicator's two error branches (a still-presented revoked key; ingestion being refused) sit
# ABOVE these in the page's chain and are reported on the API by `credential_health.revoked_key_presented`
# and `delivery_health.refusing`, so they are not states here.
#
# == The inputs
#
# The `sgk_` figures come from the {ApiKeyPartition} the caller already holds. The `sga_` agent
# credential is a third source of the same fact (SPGD-984): one agent key used across CI and agents
# must not leave a repository reading "Not connected yet" while it ingests, so the newest
# `last_used_at` across `AgentApiKey.carrying_ingest_for(repository)` joins BOTH figures (an agent
# key cannot be rotated, so it is never the stranded half). That is the one aggregate SELECT this
# object adds.
#
# == Excluding the requester (API only)
#
# `last_used_at` is stamped on the way IN, so a caller's own credential always reads "just now".
# The API therefore passes `excluding_credential:` (and a partition built with
# {ApiKeyPartition#excluding}) so the figures describe every OTHER credential. The console passes
# neither: a person's browser session is not a credential in this figure.
class RepositoryConnection
  STATES = %w[connected rotated_unused not_connected].freeze

  def self.for(repository, partition:, excluding_credential: nil)
    agent_keys = AgentApiKey.carrying_ingest_for(repository)
    agent_keys = agent_keys.where.not(id: excluding_credential.id) if excluding_credential.is_a?(AgentApiKey)

    new(partition: partition, agent_last_used_at: agent_keys.maximum(:last_used_at))
  end

  attr_reader :last_request_at, :last_live_request_at

  def initialize(partition:, agent_last_used_at:)
    @last_request_at = [partition.last_api_request_at, agent_last_used_at].compact.max
    @last_live_request_at = [partition.last_live_api_request_at, agent_last_used_at].compact.max
  end

  def state
    if last_live_request_at.present?
      "connected"
    elsif last_request_at.present?
      "rotated_unused"
    else
      "not_connected"
    end
  end

  def connected? = state == "connected"
  def rotated_unused? = state == "rotated_unused"
  def not_connected? = state == "not_connected"
end
