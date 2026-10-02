# frozen_string_literal: true

require "rails_helper"

# SPGD-984 — the `sga_` agent credential at `POST /api/v1/repositories/:repository_id/ingest`.
#
# The roadmap's done-sentence is "CI posts runs under the same key", and until this endpoint an
# agent key holding N repositories could mint keys, edit members and delete a repository but could
# not post a run. These examples pin the four decisions the owner settled: a NEW permission
# (`runs.ingest`) rather than set-membership, the repository as a PATH SEGMENT, the boundary
# recorder WIDENED to attribute an agent-key refusal from the path, and the connection indicator
# CLOSED over agent-key coverage — plus the contract under `sgk_`, which must not move.
RSpec.describe "POST /api/v1/repositories/:repository_id/ingest — the agent credential", type: :request do
  let(:person) { create_user(github_uid: "9101", github_handle: "agent-owner") }
  let(:repository) { create_repository(user: person) }
  let(:ingest_permission) { RepositoryMembership::RUNS_INGEST }

  # Eager, for the reason `agent_credential_spec.rb` gives: a lazily-minted key inside a measured
  # or counted block would count against the request.
  let!(:agent_key) do
    create_agent_api_key(user: person, repositories: [repository], permissions: [ingest_permission])
  end

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  def agent_ingest(body, key: agent_key, repository_id: repository.id, headers: {}, path: nil)
    post path || "/api/v1/repositories/#{repository_id}/ingest",
         params: body.is_a?(String) ? body : body.to_json,
         headers: { "Content-Type" => "application/json" }
           .merge(key ? bearer(key.raw_token) : {})
           .merge(headers)
  end

  describe "an agent key covering the repository and holding runs.ingest" do
    # @intent: { entity: "AgentApiKey", action: "ingest a run", behavior: "an sga_ key covering the repository and holding runs.ingest POSTs a valid payload to the path-segment route and gets 202 with the run written against that repository", layer: "request" }
    it "records the run against the repository the path names" do
      expect { agent_ingest(ingest_payload(commit_sha: "feedface01")) }
        .to change(TestRun, :count).by(1)

      expect(response).to have_http_status(:accepted)
      run = TestRun.find(response.parsed_body["test_run_id"])
      expect(run.repository).to eq(repository)
      expect(run.commit_sha).to eq("feedface01")
    end

    # One key over N repositories is the mainline, and the path is what says which one — so the run
    # lands on the NAMED repository, not on the first of the set.
    # @intent: { entity: "AgentApiKey", action: "pick the repository by path", behavior: "a key covering two repositories writes the run to the one the path names", layer: "request" }
    it "writes to the named repository when the key covers several" do
      second = create_repository(user: person, github_full_name: "acme/second")
      key = create_agent_api_key(user: person, repositories: [repository, second],
                                 permissions: [ingest_permission])

      agent_ingest(ingest_payload, key: key, repository_id: second.id)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.sole.repository).to eq(second)
    end

    # The agent's refused payload is a refused DELIVERY exactly like a `sgk_` one: same 400 body,
    # and the row lands on the path's repository.
    # @intent: { entity: "AgentApiKey", action: "refuse an invalid payload", behavior: "an invalid payload under an agent key answers 400 and records a rejection row against the path's repository", layer: "request" }
    it "refuses an invalid payload with 400 and records the rejection" do
      expect { agent_ingest({ specs: [] }) }.to change(IngestRejection, :count).by(1)

      expect(response).to have_http_status(:bad_request)
      expect(IngestRejection.sole.repository).to eq(repository)
      expect(TestRun.count).to eq(0)
    end
  end

  describe "the key's own boundaries" do
    # @intent: { entity: "AgentApiKey", action: "hide an out-of-set repository", behavior: "an sga_ key naming a repository outside its set answers 404, byte-identical to a nonexistent repository, and records nothing", layer: "request" }
    it "answers 404 for a repository outside the key's set, indistinguishable from a missing one" do
      elsewhere = create_repository(user: create_user(github_uid: "9102", github_handle: "other"),
                                    github_full_name: "acme/not-granted")

      agent_ingest(ingest_payload, repository_id: elsewhere.id)
      outside = [response.status, response.parsed_body]
      agent_ingest(ingest_payload, repository_id: elsewhere.id + 10_000)
      missing = [response.status, response.parsed_body]

      expect(outside.first).to eq(404)
      expect(outside).to eq(missing)
      expect(TestRun.count).to eq(0)
      expect(IngestRejection.count).to eq(0)
    end

    # @intent: { entity: "AgentApiKey", action: "withhold ingest without the permission", behavior: "an sga_ key covering the repository but lacking runs.ingest answers 403 and records nothing", layer: "request" }
    it "answers 403 for a covering key that lacks runs.ingest" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: [RepositoryMembership::KEYS_MANAGE])

      agent_ingest(ingest_payload, key: key)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("forbidden")
      expect(TestRun.count).to eq(0)
      expect(IngestRejection.count).to eq(0)
    end

    # The SEAM, not just the one example: `view` is implied by set membership, so a key holding
    # NOTHING reads the repository — and must still not be able to write to it. This is the
    # rejected `:view`-gate alternative, falsified.
    # @intent: { entity: "AgentApiKey", action: "keep read separate from ingest", behavior: "a read-only agent key with an empty permission set is refused 403 at ingest although it can open the repository", layer: "request" }
    it "does not let the read-implied-by-set key ingest" do
      key = create_agent_api_key(user: person, repositories: [repository], permissions: [])

      agent_ingest(ingest_payload, key: key)

      expect(response).to have_http_status(:forbidden)
      expect(TestRun.count).to eq(0)
    end

    # @intent: { entity: "AgentApiKey", action: "refuse a revoked key", behavior: "a revoked agent key at the agent ingest route answers the revoked 401 and writes no run", layer: "request" }
    it "answers the revoked 401 for a retired key" do
      agent_key.revoke!

      agent_ingest(ingest_payload)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["reason"]).to eq("revoked")
      expect(TestRun.count).to eq(0)
    end
  end

  describe "an agent key that does not name a repository" do
    # No `repository_id` in the path: a legible 400, never telemetry recorded against nil, and not
    # a 404 that would read as "that repository does not exist".
    # @intent: { entity: "AgentApiKey", action: "refuse an unnamed repository", behavior: "an sga_ key at the segment-less ingest route answers 400 naming the path-segment form and records no run and no rejection", layer: "request" }
    it "is refused 400 at the segment-less route, with the remedy named" do
      agent_ingest(ingest_payload, path: "/api/v1/ingest")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("/api/v1/repositories/:repository_id/ingest")
      expect(TestRun.count).to eq(0)
      expect(IngestRejection.count).to eq(0)
    end

    # The path is the ONLY spelling: a `repository_id` carried in the BODY must not stand in for it
    # (the boundary recorder cannot read a body, and `params` merges the two).
    # @intent: { entity: "AgentApiKey", action: "ignore a body-borne repository", behavior: "a repository_id in the JSON body does not stand in for the path segment", layer: "request" }
    it "does not accept the repository from the body" do
      agent_ingest(ingest_payload(repository_id: repository.id), path: "/api/v1/ingest")

      expect(response).to have_http_status(:bad_request)
      expect(TestRun.count).to eq(0)
    end
  end

  describe "the sgk_ contract, unchanged" do
    let(:repository_key) { repository.api_keys.create! }

    # @intent: { entity: "ApiKey", action: "keep the sgk_ route", behavior: "POST /api/v1/ingest under a sgk_ key still answers 202 and writes the run to the key's own repository", layer: "request" }
    it "still ingests at the segment-less route" do
      agent_ingest(ingest_payload, key: repository_key, path: "/api/v1/ingest")

      expect(response).to have_http_status(:accepted)
      expect(TestRun.sole.repository).to eq(repository)
    end

    # A repository named in the path under `sgk_` is IGNORED — a key that is one repository cannot
    # be asked to name a second. Even a repository the key has no relation to changes nothing:
    # same status, the run on the KEY's repository.
    # @intent: { entity: "ApiKey", action: "ignore a named repository", behavior: "a sgk_ key posting to the path-segment route naming some other repository still answers 202 and writes to its own repository", layer: "request" }
    it "ignores a repository named in the path" do
      other = create_repository(user: create_user(github_uid: "9103", github_handle: "third"),
                                github_full_name: "acme/unrelated")

      agent_ingest(ingest_payload, key: repository_key, repository_id: other.id)

      expect(response).to have_http_status(:accepted)
      expect(TestRun.sole.repository).to eq(repository)
      expect(other.test_runs.count).to eq(0)
    end
  end

  # THE RECORDER WIDEN (decision 3). A refusal decided above the controller — here an unparseable
  # body, which `JsonParseErrorResponder` answers — still leaves its row, attributed to the
  # repository the PATH names and gated by the key's own boundaries.
  describe "a refusal decided above the controller" do
    # @intent: { entity: "IngestRejection", action: "attribute an agent-key boundary refusal", behavior: "an agent-key ingest whose body will not parse still writes a rejection row attributed to the repository named by the path", layer: "request" }
    it "records an unparseable body against the path's repository" do
      expect { agent_ingest("{ not json") }.to change(IngestRejection, :count).by(1)

      expect(response).to have_http_status(:bad_request)
      rejection = IngestRejection.sole
      expect(rejection.repository).to eq(repository)
      expect(rejection.details).to eq([JsonParseErrorResponder::MESSAGE])
    end

    # The gzip leg, which is the precise payload this endpoint exists for (≥256 KiB gzipped).
    # @intent: { entity: "IngestRejection", action: "attribute an agent-key gzip refusal", behavior: "a corrupt gzip under an agent key leaves a rejection row attributed to the path's repository", layer: "request" }
    it "records a corrupt gzip body against the path's repository" do
      expect do
        agent_ingest("this is not gzip at all", headers: { "Content-Encoding" => "gzip" })
      end.to change(IngestRejection, :count).by(1)

      expect(IngestRejection.sole.repository).to eq(repository)
      expect(IngestRejection.sole.details).to eq([GzipRequestBody::CORRUPT_MESSAGE])
    end

    # The trailing-slash spellings the router resolves to the same action must record as well, on
    # the same rule the `sgk_` path states.
    ["/", "//"].each do |suffix|
      # @intent: { entity: "IngestRejection", action: "record at the routing spellings of the agent path", behavior: "a boundary refusal at a trailing-slash spelling of the agent route still records", layer: "request" }
      it "records a refusal posted to the agent route with #{suffix.inspect} appended" do
        expect do
          agent_ingest("{ not json", path: "/api/v1/repositories/#{repository.id}/ingest#{suffix}")
        end.to change(IngestRejection, :count).by(1)
      end
    end

    # The recorder must not become a write channel. A refusal the controller would have answered
    # 404/403 for leaves no row: the row claims "a delivery was refused for its payload", which is
    # false for a key that was never allowed to deliver.
    # @intent: { entity: "IngestRejection", action: "refuse to attribute beyond the key's boundaries", behavior: "an unparseable body from an agent key outside the set, or lacking runs.ingest, writes no rejection row", layer: "request" }
    it "writes no row for a key outside the set or without the permission" do
      elsewhere = create_repository(user: create_user(github_uid: "9104", github_handle: "fourth"),
                                    github_full_name: "acme/closed")
      read_only = create_agent_api_key(user: person, repositories: [repository], permissions: [])

      expect { agent_ingest("{ not json", repository_id: elsewhere.id) }
        .not_to change(IngestRejection, :count)
      expect { agent_ingest("{ not json", key: read_only) }.not_to change(IngestRejection, :count)
    end

    # The prefix/path pairing: a token at the address that does not accept it never authenticated,
    # so it leaves nothing — a `sgk_` token at the agent route, an `sga_` token at the old one.
    # @intent: { entity: "IngestRejection", action: "pair credential and address", behavior: "a sgk_ token at the agent route and an sga_ token at the segment-less route leave no boundary row", layer: "request" }
    it "writes no row for a credential presented at the address that does not accept it" do
      repository_key = repository.api_keys.create!

      expect { agent_ingest("{ not json", key: repository_key) }.not_to change(IngestRejection, :count)
      expect { agent_ingest("{ not json", path: "/api/v1/ingest") }.not_to change(IngestRejection, :count)
    end

    # @intent: { entity: "IngestRejection", action: "ignore a merely similar agent path", behavior: "a path that only resembles the agent ingest route leaves no row", layer: "request" }
    it "writes no row for a path that merely resembles the agent route" do
      # A corrupt gzip, as the `sgk_` twin of this example uses: the gzip middleware answers it
      # above the router, so the 400 is reached even though no route matches the path.
      expect do
        agent_ingest("this is not gzip at all", headers: { "Content-Encoding" => "gzip" },
                                                path: "/api/v1/repositories/#{repository.id}/ingest/extra")
      end.not_to change(IngestRejection, :count)
    end
  end

  # THE INDICATOR (decision 4): a repository whose runs arrive only under an agent key must not
  # read "Not connected yet".
  describe "the connection indicator on the repository page" do
    before { sign_in_via_github(uid: person.github_uid) }

    # @intent: { entity: "RepositoryDashboard", action: "count agent-key coverage as connected", behavior: "a repository reached only by an agent key holding runs.ingest reads Connected rather than Not connected yet", layer: "request" }
    it "reads Connected for a repository whose only traffic is an agent key" do
      agent_ingest(ingest_payload)
      expect(response).to have_http_status(:accepted)
      expect(repository.api_keys).to be_empty

      get repository_path(repository)

      indicator = Capybara.string(response.body).find("#connection-indicator")
      expect(indicator).to have_text("Connected")
      expect(indicator).to have_no_text("Not connected yet")
    end

    # The control row: the same repository before any agent key has presented anything.
    # @intent: { entity: "RepositoryDashboard", action: "keep the unused state", behavior: "a repository with an agent key that has never authenticated still reads Not connected yet", layer: "request" }
    it "still reads Not connected yet before the key has been used" do
      get repository_path(repository)

      expect(Capybara.string(response.body).find("#connection-indicator"))
        .to have_text("Not connected yet")
    end

    # A key that cannot ingest cannot be the thing connecting CI: a monitoring agent's reads stamp
    # `last_used_at` too, and must not turn the indicator green.
    # @intent: { entity: "RepositoryDashboard", action: "ignore keys that cannot ingest", behavior: "a read-only agent key that authenticated does not make the repository read Connected", layer: "request" }
    it "ignores a covering key that lacks runs.ingest" do
      reader = create_agent_api_key(user: person, repositories: [repository], permissions: [])
      get "/api/v1/repositories", headers: bearer(reader.raw_token)
      expect(reader.reload.last_used_at).to be_present

      get repository_path(repository)

      expect(Capybara.string(response.body).find("#connection-indicator"))
        .to have_text("Not connected yet")
    end

    # A revoked key's stamp is the history of a credential that no longer exists.
    # @intent: { entity: "RepositoryDashboard", action: "ignore a revoked agent key", behavior: "a revoked agent key that once ingested no longer makes the repository read Connected", layer: "request" }
    it "ignores a revoked agent key" do
      agent_ingest(ingest_payload)
      agent_key.reload.revoke!

      get repository_path(repository)

      expect(Capybara.string(response.body).find("#connection-indicator"))
        .to have_text("Not connected yet")
    end
  end
end
