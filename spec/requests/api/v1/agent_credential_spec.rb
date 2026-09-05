# frozen_string_literal: true

require "rails_helper"

# SPGD-952 — the agent credential over HTTP: the three plural reads answer to an `sga_` key,
# bounded by the key's own repository set (the read boundary — out of set is a 404, never a 403)
# and its own permission set (the verb boundary — in set without the permission is a 403), while
# ingest, the singular repository route and every person-shaped mutation refuse it.
RSpec.describe "API v1 — the agent credential (sga_)", type: :request do
  let(:person) { create_user(github_uid: "4001", github_handle: "key-owner") }
  let(:repository) { create_repository(user: person) }
  let(:other_repository) do
    create_repository(user: create_user(github_uid: "4002", github_handle: "other-owner"),
                      github_full_name: "acme/not-granted")
  end

  # The minimal, read-only grant: the repository set alone. `view` is implied by the set, exactly
  # as it is implied by a membership for a person.
  #
  # `let!` rather than `let`: several examples count queries or row changes AROUND a request, and
  # a lazily-minted key (and its repository) inside the measured block would count against the
  # request. Minted eagerly, once.
  let!(:agent_key) { create_agent_api_key(user: person, repositories: [repository], permissions: []) }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  describe "GET /api/v1/repositories" do
    # @intent: { entity: "AgentApiKey", action: "list the granted set", behavior: "an agent key listing repositories serves exactly its own granted set, and nothing outside it", layer: "request" }
    it "lists the key's own repository set" do
      get "/api/v1/repositories", headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:ok)
      names = response.parsed_body["repositories"].map { |r| r["full_name"] }
      expect(names).to eq([repository.github_full_name])
    end

    # @intent: { entity: "AgentApiKey", action: "mark the credential", behavior: "each listed repository carries role agent, the honest answer for a credential that is not a person", layer: "request" }
    it "marks every entry as role agent" do
      get "/api/v1/repositories", headers: bearer(agent_key.raw_token)

      roles = response.parsed_body["repositories"].map { |r| r["role"] }
      expect(roles).to eq(["agent"])
    end

    # `?role=` asks the OWNERSHIP partition — a person axis this credential does not have: every
    # entry serves `role: "agent"`, and there is no person in the request for the shared
    # application's `viewer.id` to read. The ask therefore clamps to the module's no-ask and the
    # whole granted set is served — the same answer an out-of-vocabulary value already gets —
    # rather than a 500 on a nil dereference or a partition that does not exist.
    # @intent: { entity: "AgentApiKey", action: "clamp an ownership ask", behavior: "an agent key asking ?role=owned or ?role=shared is served its whole granted set with a 200, never a 500", layer: "request" }
    it "serves its whole set under an ownership ask that cannot apply to it" do
      get "/api/v1/repositories", params: { role: "owned" }, headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["repositories"].map { |r| r["full_name"] })
        .to eq([repository.github_full_name])

      get "/api/v1/repositories", params: { role: "shared" }, headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["repositories"].map { |r| r["full_name"] })
        .to eq([repository.github_full_name])
    end

    # The narrowing asks the merge brought onto this surface that ARE viewer-independent are
    # honored — `?q=` filters the key's own set, and the boundary still applies FIRST: a name
    # that exists on the platform but outside the set answers an empty list, never the
    # out-of-set repository.
    # @intent: { entity: "AgentApiKey", action: "narrow by name within the set", behavior: "an agent key asking ?q= for a name outside its granted set answers an empty list, not the out-of-set repository", layer: "request" }
    it "narrows its granted set under ?q= without widening the boundary" do
      get "/api/v1/repositories", params: { q: "not-granted" }, headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["repositories"]).to eq([])
    end

    # The offboarding cut, asserted over HTTP: archiving the owner un-authenticates a key that
    # answered 200 a moment earlier, exactly as it does for the person's own `sgu_` keys.
    # @intent: { entity: "AgentApiKey", action: "retire with the owner", behavior: "archiving the minting owner stops a key that answered 200 moments earlier", layer: "request" }
    it "stops authenticating when the owner is archived" do
      get "/api/v1/repositories", headers: bearer(agent_key.raw_token)
      expect(response).to have_http_status(:ok)

      person.update!(archived_at: Time.current)

      get "/api/v1/repositories", headers: bearer(agent_key.raw_token)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/repositories/:id" do
    # @intent: { entity: "AgentApiKey", action: "read one granted repository", behavior: "an agent key opening a repository in its set serves the full overview body", layer: "request" }
    it "serves the overview body for a repository in the set" do
      get "/api/v1/repositories/#{repository.id}", headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("repository", "full_name")).to eq(repository.github_full_name)
    end

    # ⭐ THE FORK THE TICKET NAMES: a repository outside the key's set is a 404 indistinguishable
    # from a nonexistent one. Asserted against a repository that EXISTS — so the 404 is the
    # boundary working, not the absence of data.
    # @intent: { entity: "AgentApiKey", action: "hide the ungranted", behavior: "a repository outside the key's set answers 404 indistinguishable from a nonexistent one, even though it exists", layer: "request" }
    it "answers 404 for a repository outside the set, without disclosing that it exists" do
      get "/api/v1/repositories/#{other_repository.id}", headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]).to eq("not_found")
    end

    # @intent: { entity: "AgentApiKey", action: "answer a bogus id", behavior: "a malformed id lands on the same 404 with no raise", layer: "request" }
    it "answers 404 for an id that is no integer" do
      get "/api/v1/repositories/not-an-id", headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/repositories/:repository_id/members" do
    # @intent: { entity: "AgentApiKey", action: "read members", behavior: "an agent key holding members.manage on a granted repository lists its members", layer: "request" }
    it "lists members for a key holding members.manage on a repository in the set" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])
      create_membership(repository: repository, user: create_user(github_uid: "4003",
                                                                  github_handle: "collab"))

      get "/api/v1/repositories/#{repository.id}/members", headers: bearer(key.raw_token)

      expect(response).to have_http_status(:ok)
      handles = response.parsed_body["members"].map { |m| m["handle"] }
      expect(handles).to include("collab")
    end

    # THE VERB BOUNDARY: authenticated, repository in set, permission missing — so the caller is
    # told the truth (403) rather than hidden from (404), on the same fork a person is.
    # @intent: { entity: "AgentApiKey", action: "refuse an unpermitted read", behavior: "an in-set repository asked for members by a key without members.manage answers 403", layer: "request" }
    it "answers 403 for a member listing without the members.manage permission" do
      get "/api/v1/repositories/#{repository.id}/members", headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("forbidden")
    end

    # @intent: { entity: "AgentApiKey", action: "hide the ungranted set", behavior: "members listing on a repository outside the key's set answers 404, the read boundary, even with the permission held", layer: "request" }
    it "answers 404 for members of a repository outside the set, even holding the permission" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])

      get "/api/v1/repositories/#{other_repository.id}/members", headers: bearer(key.raw_token)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the surfaces the agent credential never reaches" do
    # THE TWO sgk_-ONLY ROUTES. The prefix matches nothing these endpoints declare, so the refusal
    # reads no table — asserted, not assumed, because a probing implementation produces the same
    # 401 at twice the cost.
    # @intent: { entity: "AgentApiKey", action: "refuse at ingest", behavior: "an agent key at the ingest endpoint answers 401 with zero credential-table reads", layer: "request" }
    it "is refused by POST /api/v1/ingest with no credential read at all" do
      token = agent_key.raw_token

      statements = queries_against(/api_keys/) do
        post "/api/v1/ingest", params: ingest_payload, as: :json, headers: bearer(token)
      end

      expect(response).to have_http_status(:unauthorized)
      expect(statements).to be_empty
    end

    # @intent: { entity: "AgentApiKey", action: "refuse at the singular route", behavior: "an agent key at GET /api/v1/repository answers 401", layer: "request" }
    it "is refused by GET /api/v1/repository" do
      get "/api/v1/repository", headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
    end

    # THE PERSON-SHAPED MUTATIONS. The token is valid and of a class the endpoint accepts, so the
    # refusal is 403 — "you may not", not "who are you?" — from `require_person_credential`.
    # @intent: { entity: "AgentApiKey", action: "refuse registration", behavior: "an agent key cannot register a repository; the person-only action answers 403", layer: "request" }
    it "cannot register a repository" do
      expect {
        post "/api/v1/repositories", params: { github_full_name: "acme/new-thing" }.to_json,
                                     headers: bearer(agent_key.raw_token).merge(
                                       "Content-Type" => "application/json"
                                     )
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # @intent: { entity: "AgentApiKey", action: "refuse rename", behavior: "an agent key cannot rename a repository, even one in its set", layer: "request" }
    it "cannot rename a repository" do
      patch "/api/v1/repositories/#{repository.id}",
            params: { github_full_name: "acme/renamed" }.to_json,
            headers: bearer(agent_key.raw_token).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:forbidden)
      expect(repository.reload.github_full_name).to eq(repository.github_full_name)
    end

    # Even a key holding the repo.delete PERMISSION cannot delete: the permission vocabulary is
    # shared, the agent surface is read-only. The guard fires before the policy is ever asked.
    # @intent: { entity: "AgentApiKey", action: "refuse deletion", behavior: "an agent key holding repo.delete still cannot destroy a repository", layer: "request" }
    it "cannot destroy a repository even holding repo.delete" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["repo.delete"])

      expect {
        delete "/api/v1/repositories/#{repository.id}", headers: bearer(key.raw_token)
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # @intent: { entity: "AgentApiKey", action: "refuse member mutation", behavior: "an agent key cannot add a member, even holding members.manage", layer: "request" }
    it "cannot add a member even holding members.manage" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])

      expect {
        post "/api/v1/repositories/#{repository.id}/members",
             params: { handle: "collab", permissions: ["view"] }.to_json,
             headers: bearer(key.raw_token).merge("Content-Type" => "application/json")
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "a revoked agent key" do
    # The retirement, over HTTP: the token stops, the ROW STAYS — which is what makes the refusal
    # attributable to a row rather than to nothing.
    # @intent: { entity: "AgentApiKey", action: "revoke", behavior: "a revoked agent key answers 401 while its row is retained", layer: "request" }
    it "stops authenticating while the row is retained" do
      token = agent_key.raw_token
      agent_key.revoke!

      get "/api/v1/repositories", headers: bearer(token)

      expect(response).to have_http_status(:unauthorized)
      expect(AgentApiKey.revoked.exists?(agent_key.id)).to be(true)
    end

    # @intent: { entity: "AgentApiKey", action: "leave refused key unstamped", behavior: "the refusal leaves the revoked key last_used_at nil, so rejection never masquerades as a use", layer: "request" }
    it "does not stamp the refused presentation as a use" do
      token = agent_key.raw_token
      agent_key.revoke!

      get "/api/v1/repositories", headers: bearer(token)

      expect(agent_key.reload.last_used_at).to be_nil
    end
  end

  describe "the cost of a valid presentation" do
    # The base controller's claim, held for the third credential too: prefix dispatch decides the
    # table, resolution is one indexed read on it, and the stamp is the only write. The PERSON is
    # never re-read (the eager_loaded owner rides the resolving statement, and nothing downstream
    # wants them), and the members query below is the endpoint's own PAYLOAD — the same reads a
    # person key pays — not an authorization cost.
    # @intent: { entity: "AgentApiKey", action: "resolve in one read", behavior: "a valid agent presentation costs one credential select plus the last_used_at stamp, the person never re-read", layer: "request" }
    it "resolves in one credential read, and the authorization reads no person" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])

      statements = queries_against(/api_keys|"users"/) do
        get "/api/v1/repositories/#{repository.id}/members", headers: bearer(key.raw_token)
      end

      expect(response).to have_http_status(:ok)
      expect(statements.grep(/FROM "agent_api_keys"/).size).to eq(1)
      expect(statements.grep(/FROM "api_keys"/)).to be_empty
      expect(statements.grep(/FROM "users"/)).to be_empty
      expect(statements.grep(/UPDATE "agent_api_keys"/).size).to eq(1)
    end
  end
end
