# frozen_string_literal: true

require "rails_helper"

# SPGD-1004 — the API half SPGD-989 scoped out and SPGD-993 fenced to this lane: a repository's
# `sga_` agent-key inventory and its `keys.manage`-gated revocation, over a Bearer token. The
# web pair (`repositories/_agent_keys` + `RepositoryAgentKeysController`) is session- and
# CSRF-closed to a token-holder by construction, and SPGD-993 gave the `sgk_` sibling this
# exact pair over the API — so these examples pin the port on both axes at once:
#
#   * GATE SYMMETRY — the same principal matrix `user_repository_admin_spec.rb` walks for the
#     `sgk_` pair (keys.manage holder / view-only member / stranger / a repository's own key)
#     yields the same refusals here. Asserted rather than assumed: "the same gate" is exactly
#     the kind of claim that silently stops being true, and the whole point of the port is
#     that it changed no authorization.
#   * BOTH CREDENTIALS — the pair answers to an `sga_` agent key bounded by its own stored set
#     and permission set, and to an `sgu_` user key bounded by its holder's rights.
#   * THE DISCLOSURE — over the API there is no confirm dialog, so the revoke response carries
#     the key's FULL stored set (count + names), the disclosure the web confirm renders before
#     the cut and its notice after it.
RSpec.describe "API v1 — repository agent keys over a Bearer token", type: :request do
  let(:owner) { create_user(github_uid: "6001", github_handle: "octocat") }
  let(:repository) { create_repository(user: owner, github_full_name: "acme/billing-service") }
  let(:owner_key) { create_user_api_key(user: owner) }

  let(:member) { create_user(github_uid: "6999", github_handle: "hubot") }
  let(:member_key) { create_user_api_key(user: member) }
  let(:stranger) { create_user(github_uid: "6777", github_handle: "locutus") }
  let(:stranger_key) { create_user_api_key(user: stranger) }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  def index_path(repo = repository) = "/api/v1/repositories/#{repo.id}/agent_keys"
  def revoke_path(key, repo = repository) = "/api/v1/repositories/#{repo.id}/agent_keys/#{key.id}"

  # The granted principal the offboarding arc is about: an `sga_` key whose stored set covers
  # `repository` and whose permission set carries `keys.manage` there. `member` is the same
  # holder as a person, for the `sgu_` half of the matrix.
  let!(:agent_key) do
    create_membership(repository: repository, user: member, permissions: %w[view keys.manage])
    create_agent_api_key(user: member, repositories: [repository],
                         permissions: [RepositoryMembership::KEYS_MANAGE])
  end

  describe "GET /api/v1/repositories/:repository_id/agent_keys" do
    # @intent: { entity: "AgentApiKey", action: "list the inventory", behavior: "an sga_ key holding keys.manage lists the repository's live covering agent keys with the web panel's row as JSON, and never a token", layer: "request" }
    it "serves the web panel's row as JSON to an sga_ key holding keys.manage" do
      get index_path, headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body["agent_keys"]
      expect(rows.map { |r| r["id"] }).to eq([agent_key.id])

      row = rows.first
      expect(row.keys).to contain_exactly("id", "name", "owner", "token_hint",
                                          "repository_count", "permissions", "created_at")
      expect(row["name"]).to eq(agent_key.name)
      expect(row["owner"]).to eq("hubot")
      expect(row["token_hint"]).to eq(agent_key.reload.token_hint)
      expect(row["repository_count"]).to eq(1)
      expect(row["permissions"]).to eq("keys.manage")
      expect(row["created_at"]).to eq(agent_key.created_at.iso8601)

      # The token itself is not among the served fields — under ANY spelling. The plaintext
      # existed for exactly one response at mint time and nothing persisted it.
      expect(row.keys).not_to include("token")
      expect(JSON.parse(response.body)).not_to include("token")
    end

    # The minimal grant the model explicitly allows renders the panel's honest phrase, not an
    # empty string — the same rendering /account gives the same column.
    # @intent: { entity: "AgentApiKey", action: "render the minimal grant", behavior: "a key whose permission set is empty serves permissions read only, the web panel's rendering", layer: "request" }
    it "renders an empty permission set as read only" do
      minimal = create_agent_api_key(user: owner, repositories: [repository], permissions: [])

      get index_path, headers: bearer(owner_key.raw_token)

      row = response.parsed_body["agent_keys"].find { |r| r["id"] == minimal.id }
      expect(row["permissions"]).to eq("read only")
    end

    # AC2 — the same inventory, same shape, same population, over a person key. The two
    # credential classes are served by the one gate, so the lists cannot disagree.
    # @intent: { entity: "AgentApiKey", action: "serve both credentials identically", behavior: "an sgu_ key of a keys.manage holder reads the same rows with the same fields as the sga_ key", layer: "request" }
    it "serves the identical inventory to an sgu_ key of a keys.manage holder" do
      get index_path, headers: bearer(agent_key.raw_token)
      agent_view = response.parsed_body["agent_keys"]

      get index_path, headers: bearer(member_key.raw_token)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["agent_keys"]).to eq(agent_view)
    end

    # LIVE-only population (SPGD-804's rule on this table): a revoked row is retained but is
    # not a credential, so the next GET moves on without it — the same rule the web panel
    # follows by handing its partial live rows alone.
    # @intent: { entity: "AgentApiKey", action: "drop a retired row", behavior: "a revoked key leaves the inventory on the next GET", layer: "request" }
    it "leaves a revoked key off the inventory on the next GET" do
      agent_key.revoke!

      get index_path, headers: bearer(member_key.raw_token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["agent_keys"]).to eq([])
    end

    # The null-safe owner fork the web cell carries. A request-level example cannot reach the
    # fork — `agent_api_keys.user_id` is NOT NULL **and** carries a real foreign key, so no
    # writable row has an owner id that matches no user (the DB refusing a dangling id is the
    # demonstration) — so the rendering is pinned on the serializer directly, the same way the
    # panel's cell is written: nil in, "Unknown" out, no exception.
    # @intent: { entity: "AgentApiKey", action: "render a missing owner", behavior: "a row with no resolvable owner serializes owner as the panel's Unknown rather than raising", layer: "request" }
    it "renders an unresolvable owner as Unknown" do
      orphan = AgentApiKey.new(name: "Orphan", user: nil, repository_ids: [repository.id],
                               permissions: [], token_digest: "digest", created_at: Time.current)

      serialized = Api::V1::UserRepositoryAgentKeysController.new.send(:serialize, orphan)

      expect(serialized[:owner]).to eq("Unknown")
    end

    # THE GATE, refusals asserted on this route rather than inherited from the sibling's: a
    # repository's own `sgk_` key speaks for the repository, not for anybody who may administer
    # its keys — 401 at the credential layer, before any capability is asked.
    # @intent: { entity: "credential seam", action: "refuse a repository key at the inventory", behavior: "an sgk_ repository key at the agent-key inventory answers 401", layer: "request" }
    it "answers 401 to a repository's own sgk_ key" do
      sgk_token = repository.api_keys.create!.raw_token

      get index_path, headers: bearer(sgk_token)

      expect(response).to have_http_status(:unauthorized)
    end

    # @intent: { entity: "AgentApiKey", action: "refuse an unpermitted read", behavior: "an in-set sga_ key without keys.manage answers 403 with the api error JSON", layer: "request" }
    it "answers 403 to an in-set sga_ key without keys.manage" do
      read_only = create_agent_api_key(user: owner, repositories: [repository], permissions: [])

      get index_path, headers: bearer(read_only.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
      expect(response.media_type).to eq("application/json")
    end

    # The read boundary: a repository outside the key's stored set is a 404 indistinguishable
    # from a nonexistent one, even holding keys.manage — the key's set bounds the read before
    # any capability question.
    # @intent: { entity: "AgentApiKey", action: "hide the out-of-set inventory", behavior: "the inventory of a repository outside an sga_ key's set answers 404, even with keys.manage held", layer: "request" }
    it "answers 404 to an sga_ key whose set excludes the repository, even holding keys.manage" do
      elsewhere = create_agent_api_key(user: owner, repositories: [repository],
                                       permissions: [RepositoryMembership::KEYS_MANAGE])
      other = create_repository(user: owner, github_full_name: "acme/other-service")

      get index_path(other), headers: bearer(elsewhere.raw_token)

      expect(response).to have_http_status(:not_found)
    end

    # @intent: { entity: "user key", action: "refuse a view member", behavior: "an sgu_ holder with only view answers 403", layer: "request" }
    it "answers 403 to an sgu_ holder with only view" do
      create_membership(repository: repository, user: stranger, permissions: %w[view])

      get index_path, headers: bearer(stranger_key.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
    end

    # @intent: { entity: "user key", action: "hide the inventory from a non-member", behavior: "a non-member sgu_ holder answers 404 and an unknown repository id answers 404 for a holder too", layer: "request" }
    it "answers 404 to a non-member and for an id that is no repository" do
      get index_path, headers: bearer(stranger_key.raw_token)
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("error" => "not_found")

      get index_path(Repository.new(id: 999_999)), headers: bearer(owner_key.raw_token)
      expect(response).to have_http_status(:not_found)
    end

    # THE N+1 GUARD, in the per-table budget discipline the sibling inventory pins: under an
    # `sgu_` credential (whose own authentication statement names `user_api_keys`, matching
    # neither pattern below) the whole listing is ONE statement against `agent_api_keys` —
    # `eager_load(:user)` paying the owner join inside it — no matter how many rows.
    # @intent: { entity: "AgentApiKey", action: "read the list cheaply", behavior: "the inventory costs one agent_api_keys statement for the whole list, the owner join inside it, never one query per row", layer: "request" }
    it "pays one statement for the whole list, the owner join inside it" do
      create_agent_api_key(user: owner, repositories: [repository],
                           permissions: [RepositoryMembership::KEYS_MANAGE])
      token = owner_key.raw_token

      statements = queries_against(/agent_api_keys/) do
        get index_path, headers: bearer(token)
      end

      expect(response).to have_http_status(:ok)
      expect(statements.grep(/FROM "agent_api_keys"/).size).to eq(1)
    end
  end

  describe "DELETE /api/v1/repositories/:repository_id/agent_keys/:id" do
    # The offboarding shape the endpoint exists for: the key outlives its minter's membership
    # and still authenticates until somebody retires it.
    # @intent: { entity: "AgentApiKey", action: "revoke an outliving key", behavior: "an sga_ key holding keys.manage retires an outliving agent key: 200 with the full stored set, the row retained and stamped, the token refusing at the API", layer: "request" }
    it "retires the key and discloses the full stored set in the response that performs the cut" do
      revoked_token = agent_key.raw_token

      expect {
        delete revoke_path(agent_key), headers: bearer(agent_key.raw_token)
      }.not_to change(AgentApiKey, :count)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["agent_key"]
      expect(body["id"]).to eq(agent_key.id)
      expect(body["name"]).to eq(agent_key.name)
      expect(body["repository_count"]).to eq(1)
      expect(body["repositories"]).to eq(["acme/billing-service"])

      # Retirement, not deletion (the pattern `ApiKey#revoke!` established): the row survives,
      # stamped — and the dead token stops resolving, asserted through `authenticate` because
      # resolving a Bearer token is the only thing the row's survival would actually mean.
      expect(agent_key.reload.revoked_at).to be_present
      expect(body["revoked_at"]).to eq(agent_key.reload.revoked_at.iso8601)
      expect(AgentApiKey.authenticate(revoked_token)).to be_nil
    end

    # The blast radius is the whole stored SET: a key minted over two repositories is cut on
    # both by one act over one of them, and the response is where the caller is told so —
    # the disclosure the web confirm renders before the cut, with no confirm over the API.
    # @intent: { entity: "AgentApiKey", action: "disclose a multi-repository cut", behavior: "revoking a two-repository key answers with count and both names and stops the token everywhere", layer: "request" }
    it "cuts a multi-repository key everywhere and names the whole set in the response" do
      second = create_repository(user: owner, github_full_name: "acme/second-service")
      wide = create_agent_api_key(user: owner, repositories: [repository, second],
                                  permissions: [])

      delete revoke_path(wide), headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["agent_key"]
      expect(body["repository_count"]).to eq(2)
      expect(body["repositories"]).to eq(%w[acme/billing-service acme/second-service])

      expect(AgentApiKey.authenticate(wide.raw_token)).to be_nil
      # Retired rows leave BOTH repositories' inventories on the next GET.
      get index_path, headers: bearer(owner_key.raw_token)
      expect(response.parsed_body["agent_keys"].map { |r| r["id"] }).not_to include(wide.id)
    end

    # Repositories deleted since mint drop out of the names on their own; the count stays the
    # stored set's size and the difference is disclosed, the coverage sentence's own
    # "(N repositories since deleted)" parenthetical.
    # @intent: { entity: "AgentApiKey", action: "disclose deletions", behavior: "a stored set naming a repository deleted since mint serves a smaller name list with deleted_repository_count set", layer: "request" }
    it "discloses repositories deleted since mint rather than letting count and names disagree" do
      vanished = create_repository(user: owner, github_full_name: "acme/vanished-service")
      wide = create_agent_api_key(user: owner, repositories: [repository, vanished],
                                  permissions: [])
      vanished.destroy!

      delete revoke_path(wide), headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["agent_key"]
      expect(body["repository_count"]).to eq(2)
      expect(body["repositories"]).to eq(["acme/billing-service"])
      expect(body["deleted_repository_count"]).to eq(1)
    end

    # @intent: { entity: "AgentApiKey", action: "revoke over a person key", behavior: "an sgu_ key of a keys.manage holder retires the key through the same gate", layer: "request" }
    it "revokes for an sgu_ key of a keys.manage holder" do
      delete revoke_path(agent_key), headers: bearer(member_key.raw_token)

      expect(response).to have_http_status(:ok)
      expect(agent_key.reload.revoked_at).to be_present
    end

    # AC6 — the `covers?` bound: a keys.manage holder of repo A may not revoke a key whose
    # stored set excludes A, and the refusal is a 404 — out of boundary reads as out of
    # existence, the fork every repository-scoped read takes.
    # @intent: { entity: "AgentApiKey", action: "bound revoke to the acting repository", behavior: "deleting a key that does not cover the acting repository answers 404 and leaves the key live", layer: "request" }
    it "answers 404 for a key whose set excludes the acting repository" do
      other = create_repository(user: owner, github_full_name: "acme/other-service")
      elsewhere = create_agent_api_key(user: owner, repositories: [other],
                                       permissions: [RepositoryMembership::KEYS_MANAGE])

      expect {
        delete revoke_path(elsewhere), headers: bearer(owner_key.raw_token)
      }.not_to change { elsewhere.reload.revoked_at }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("error" => "not_found")
    end

    # A revoked row is retained but is not a credential, so the replayed DELETE finds nothing
    # on the usual `live.find` 404.
    # @intent: { entity: "AgentApiKey", action: "refuse a replayed revoke", behavior: "deleting an already-revoked key answers 404 and re-stamps nothing", layer: "request" }
    it "does not find an already-revoked key" do
      agent_key.revoke!
      stamped_at = agent_key.reload.revoked_at

      delete revoke_path(agent_key), headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:not_found)
      expect(agent_key.reload.revoked_at).to eq(stamped_at)
    end

    # @intent: { entity: "credential seam", action: "refuse a repository key at the revoke", behavior: "an sgk_ repository key at the agent-key revoke answers 401 and leaves the key live", layer: "request" }
    it "answers 401 to a repository's own sgk_ key" do
      sgk_token = repository.api_keys.create!.raw_token

      expect {
        delete revoke_path(agent_key), headers: bearer(sgk_token)
      }.not_to change { agent_key.reload.revoked_at }

      expect(response).to have_http_status(:unauthorized)
    end

    # @intent: { entity: "AgentApiKey", action: "refuse an unpermitted revoke", behavior: "an in-set sga_ key without keys.manage answers 403 and leaves the key live", layer: "request" }
    it "answers 403 to an in-set sga_ key without keys.manage" do
      read_only = create_agent_api_key(user: owner, repositories: [repository], permissions: [])

      expect {
        delete revoke_path(agent_key), headers: bearer(read_only.raw_token)
      }.not_to change { agent_key.reload.revoked_at }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
    end

    # @intent: { entity: "user key", action: "refuse a view member at revoke", behavior: "an sgu_ holder with only view answers 403 and leaves the key live", layer: "request" }
    it "answers 403 to an sgu_ holder with only view" do
      create_membership(repository: repository, user: stranger, permissions: %w[view])

      expect {
        delete revoke_path(agent_key), headers: bearer(stranger_key.raw_token)
      }.not_to change { agent_key.reload.revoked_at }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
    end

    # @intent: { entity: "user key", action: "hide the revoke from a non-member", behavior: "a non-member sgu_ holder answers 404 and leaves the key live, as does an unknown repository id", layer: "request" }
    it "answers 404 to a non-member and for an unknown repository id" do
      expect {
        delete revoke_path(agent_key), headers: bearer(stranger_key.raw_token)
      }.not_to change { agent_key.reload.revoked_at }

      expect(response).to have_http_status(:not_found)

      expect {
        delete revoke_path(agent_key, Repository.new(id: 999_999)),
               headers: bearer(owner_key.raw_token)
      }.not_to change { agent_key.reload.revoked_at }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the routes (AC7)" do
    # The namespace gains exactly the two new routes; the sgk_ sibling, the web resource and
    # /account are untouched — asserted by recognition here and by the specs that already pin
    # those surfaces' behaviour.
    # @intent: { entity: "routes", action: "mount the pair", behavior: "the two new api routes recognize to user_repository_agent_keys and the sgk_ inventory route still recognizes to user_repository_api_keys", layer: "request" }
    it "recognizes the two new routes and leaves the sgk_ route pointing at its own controller" do
      expect(Rails.application.routes.recognize_path(index_path, method: :get))
        .to include(controller: "api/v1/user_repository_agent_keys", action: "index")
      expect(Rails.application.routes.recognize_path(revoke_path(agent_key), method: :delete))
        .to include(controller: "api/v1/user_repository_agent_keys", action: "destroy")

      expect(
        Rails.application.routes.recognize_path(
          "/api/v1/repositories/#{repository.id}/api_keys", method: :get
        )
      ).to include(controller: "api/v1/user_repository_api_keys", action: "index")
    end
  end
end
