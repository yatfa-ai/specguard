# frozen_string_literal: true

require "rails_helper"

# SPGD-2024 — `credential_health.connection` on the repository overview, on BOTH routes.
#
# A caller with a view-only key used to get only negatives from a repository that had never
# reported, so "CI never wired", "wired but key never used" and "authenticating but nothing
# accepted" read identically. The block serves the connection indicator's three non-error states
# (`connected` / `rotated_unused` / `not_connected`) from `RepositoryConnection`, the same object
# the page's indicator reads.
#
# THE TRAP these examples pin: the requesting credential has just stamped its own `last_used_at`,
# so it is EXCLUDED from both figures — otherwise every response would read "connected, just now".
RSpec.describe "repository overview — credential_health.connection", type: :request do
  let(:person) { create_user(github_uid: "7001", github_handle: "conn-owner") }
  let(:repository) { create_repository(user: person) }
  let(:ingest_permission) { RepositoryMembership::RUNS_INGEST }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  def connection_via(path, token)
    get path, headers: bearer(token)
    expect(response).to have_http_status(:ok)
    response.parsed_body.dig("credential_health", "connection")
  end

  # Each route's caller, and the row that represents it among the repository's credentials.
  shared_examples "an overview route" do
    # @intent: { entity: "credential_health.connection", action: "serve the wire contract", behavior: "the block carries state, both timestamps, the exclusion disclosure and the acceptance pointer to delivery_health", layer: "request" }
    it "serves the full block with its disclosures" do
      expect(connection.keys).to match_array(
        %w[state last_request_at last_live_request_at excludes_requesting_credential acceptance_reported_by]
      )
      expect(connection["excludes_requesting_credential"]).to be(true)
      expect(connection["acceptance_reported_by"]).to eq("delivery_health")
    end

    # @intent: { entity: "credential_health.connection", action: "read not_connected for a never-used sibling", behavior: "a repository whose only other key has never authenticated is not_connected with null timestamps", layer: "request" }
    it "reads not_connected when no other credential has ever authenticated" do
      repository.api_keys.create!(name: "Never used")

      expect(connection).to include("state" => "not_connected", "last_request_at" => nil,
                                    "last_live_request_at" => nil)
    end

    # @intent: { entity: "credential_health.connection", action: "read connected from a used sibling", behavior: "another key's use makes the repository connected and dates both figures", layer: "request" }
    it "reads connected from another key's use" do
      other = repository.api_keys.create!(name: "CI")
      other.touch_last_used!

      expect(connection).to include("state" => "connected",
                                    "last_request_at" => other.reload.last_used_at.iso8601,
                                    "last_live_request_at" => other.last_used_at.iso8601)
    end

    # @intent: { entity: "credential_health.connection", action: "read rotated_unused", behavior: "when every key that ever authenticated has since been rotated, the state is rotated_unused with a last_request_at and no last_live_request_at", layer: "request" }
    it "reads rotated_unused when the only token that authenticated has been rotated away" do
      other = repository.api_keys.create!(name: "CI")
      other.touch_last_used!
      other.update_columns(last_used_at: 2.hours.ago)
      other.regenerate!

      expect(connection).to include("state" => "rotated_unused", "last_live_request_at" => nil)
      expect(connection["last_request_at"]).to eq(other.reload.last_used_at.iso8601)
    end

    # @intent: { entity: "credential_health.connection", action: "count an ingest-carrying agent key", behavior: "another sga_ key holding runs.ingest and covering the repository makes it connected", layer: "request" }
    it "counts another agent key that carries ingest" do
      other = create_agent_api_key(user: person, repositories: [repository], permissions: [ingest_permission],
                                   name: "Other agent")
      other.touch_last_used!

      expect(connection).to include("state" => "connected",
                                    "last_live_request_at" => other.reload.last_used_at.iso8601)
    end

    # @intent: { entity: "credential_health.connection", action: "ignore an agent key without ingest", behavior: "an sga_ key lacking runs.ingest does not make the repository connected", layer: "request" }
    it "ignores another agent key that cannot carry ingest" do
      other = create_agent_api_key(user: person, repositories: [repository], permissions: [], name: "Reader")
      other.touch_last_used!

      expect(connection["state"]).to eq("not_connected")
    end

    # @intent: { entity: "credential_health.connection", action: "agree with the console", behavior: "the API state equals the state RepositoryConnection derives for the same repository", layer: "request" }
    it "gives the state the shared derivation gives" do
      other = repository.api_keys.create!(name: "CI")
      other.touch_last_used!

      partition = ApiKeyPartition.for(repository.api_keys.reload.to_a).excluding(requester)
      expected = RepositoryConnection.for(repository, partition: partition, excluding_credential: requester)

      expect(connection["state"]).to eq(expected.state)
    end
  end

  describe "GET /api/v1/repository (sgk_)" do
    let!(:requester) { repository.api_keys.create!(name: "Caller") }
    let(:connection) { connection_via("/api/v1/repository", requester.raw_token) }

    include_examples "an overview route"

    # @intent: { entity: "credential_health.connection", action: "exclude the caller", behavior: "a repository whose only authenticating key is the caller reads not_connected, never connected", layer: "request" }
    it "does not count the requesting key as a request" do
      expect(connection).to include("state" => "not_connected", "last_request_at" => nil)
      expect(requester.reload.last_used_at).to be_present
    end
  end

  describe "GET /api/v1/repositories/:id (sgu_)" do
    let!(:requester) { create_user_api_key(user: person) }
    let(:connection) { connection_via("/api/v1/repositories/#{repository.id}", requester.raw_token) }

    include_examples "an overview route"
  end

  describe "GET /api/v1/repositories/:id (sga_)" do
    let!(:requester) do
      create_agent_api_key(user: person, repositories: [repository], permissions: [ingest_permission],
                           name: "Caller agent")
    end
    let(:connection) { connection_via("/api/v1/repositories/#{repository.id}", requester.raw_token) }

    include_examples "an overview route"

    # @intent: { entity: "credential_health.connection", action: "exclude the calling agent key", behavior: "an ingest-carrying sga_ caller that is the only authenticating credential reads not_connected, not connected", layer: "request" }
    it "does not count the requesting agent key as a request" do
      expect(connection).to include("state" => "not_connected", "last_request_at" => nil)
      expect(requester.reload.last_used_at).to be_present
    end
  end
end
