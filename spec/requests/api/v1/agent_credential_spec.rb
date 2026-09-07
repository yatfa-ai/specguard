# frozen_string_literal: true

require "rails_helper"

# SPGD-952 — the agent credential over HTTP: the three plural reads answer to an `sga_` key,
# bounded by the key's own repository set (the read boundary — out of set is a 404, never a 403)
# and its own permission set (the verb boundary — in set without the permission is a 403), while
# ingest, the singular repository route and the person-anchored mutations (register, rename)
# refuse it.
#
# SPGD-973 — the write verbs answer to the same two boundaries: mint/revoke `sgk_` keys under
# `keys.manage`, member add/edit/revoke under `members.manage`, repository deletion under
# `repo.delete`. Every write under an agent credential passes the 404/403 fork the reads do, plus
# two bounds of its own: the key cannot GRANT a permission it does not itself hold (member
# writes), and every grant is attributed to the key's OWNER so the model's grantor bound keeps
# measuring a real person's rights.
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

  # ---------------------------------------------------------------- SPGD-973
  # The write verbs, opened to the agent credential on the key's own terms: same routes, same
  # capability gates, same 404/403 fork the reads answer. Every example below holds the two
  # boundaries together — the SET boundary (out of set is a 404 even with the permission held)
  # and the VERB boundary (in set without the permission is a 403) — and the member writes add
  # the two bounds that make a machine credential safe on a mutating surface: the key cannot
  # GRANT what it does not hold, and every grant is attributed to the key's OWNER so the model's
  # grantor bound keeps measuring a real person's rights.

  describe "POST /api/v1/repositories/:repository_id/api_keys" do
    # The minted body is deliberately unchanged: an agent-minted key reads exactly like a
    # person-minted one, because it IS one — same `api_key` block, same reveal-once token.
    # @intent: { entity: "AgentApiKey", action: "mint a repository key", behavior: "an agent key holding keys.manage mints a repository key whose body carries the person-minted shape with the reveal-once token", layer: "request" }
    it "mints a repository key for a key holding keys.manage on a repository in the set" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["keys.manage"])

      expect {
        post "/api/v1/repositories/#{repository.id}/api_keys",
             params: { name: "Second pipeline" }.to_json,
             headers: bearer(key.raw_token).merge("Content-Type" => "application/json")
      }.to change(ApiKey, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["api_key"].keys)
        .to contain_exactly("name", "token", "hint", "created_at")
      expect(response.parsed_body["api_key"]["token"]).to be_present
    end

    # The attribution decision this slice makes explicitly: the minted row's creator is the
    # KEY'S OWNER — a person the account page can name and `keys_minted_by` can count — not
    # nil ("Unknown").
    # @intent: { entity: "AgentApiKey", action: "attribute a mint", behavior: "a repository key minted under an agent credential records the agent key's owner as its creator", layer: "request" }
    it "records the agent key's owner as the minted key's creator" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["keys.manage"])

      post "/api/v1/repositories/#{repository.id}/api_keys", headers: bearer(key.raw_token)

      expect(response).to have_http_status(:created)
      expect(ApiKey.order(:id).last.created_by_user).to eq(person)
    end

    # @intent: { entity: "AgentApiKey", action: "refuse an unpermitted mint", behavior: "an in-set repository asked for a mint by a key without keys.manage answers 403", layer: "request" }
    it "answers 403 without the keys.manage permission" do
      post "/api/v1/repositories/#{repository.id}/api_keys", headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("forbidden")
    end

    # @intent: { entity: "AgentApiKey", action: "hide the ungranted mint", behavior: "a mint on a repository outside the key's set answers 404, even with keys.manage held", layer: "request" }
    it "answers 404 for a repository outside the set, even holding keys.manage" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["keys.manage"])

      post "/api/v1/repositories/#{other_repository.id}/api_keys", headers: bearer(key.raw_token)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/repositories/:repository_id/api_keys/:id" do
    # @intent: { entity: "AgentApiKey", action: "revoke a repository key", behavior: "an agent key holding keys.manage revokes one of the repository's own keys, the row retained", layer: "request" }
    it "revokes a repository key for a key holding keys.manage on a repository in the set" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["keys.manage"])
      repository_key = repository.api_keys.create!(name: "CI")

      delete "/api/v1/repositories/#{repository.id}/api_keys/#{repository_key.id}",
             headers: bearer(key.raw_token)

      expect(response).to have_http_status(:no_content)
      expect(repository_key.reload.revoked_at).to be_present
    end

    # @intent: { entity: "AgentApiKey", action: "refuse an unpermitted revoke", behavior: "a revoke without keys.manage answers 403 and leaves the key live", layer: "request" }
    it "answers 403 without the keys.manage permission, leaving the key live" do
      repository_key = repository.api_keys.create!(name: "CI")

      delete "/api/v1/repositories/#{repository.id}/api_keys/#{repository_key.id}",
             headers: bearer(agent_key.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(repository_key.reload.revoked_at).to be_nil
    end
  end

  describe "POST /api/v1/repositories/:repository_id/members" do
    # @intent: { entity: "AgentApiKey", action: "add a member", behavior: "an agent key holding members.manage adds a member by handle on a repository in its set", layer: "request" }
    it "adds a member for a key holding members.manage on a repository in the set" do
      collab = create_user(github_uid: "4010", github_handle: "collab")
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])

      expect {
        post "/api/v1/repositories/#{repository.id}/members",
             params: { handle: collab.github_handle, permissions: ["view"] }.to_json,
             headers: bearer(key.raw_token).merge("Content-Type" => "application/json")
      }.to change(RepositoryMembership, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["member"]["handle"]).to eq(collab.github_handle)
    end

    # THE ATTRIBUTION CRITERION, asserted on the row: the grant of record names the key's OWNER.
    # A nil grantor would not merely mislabel the row — `grantor_holds_every_granted_permission`
    # fails OPEN on nil — so a NULL here would be the SPGD-103 two-step escalation reopened, and
    # this example is the one that catches it.
    # @intent: { entity: "AgentApiKey", action: "attribute a grant", behavior: "a member added under an agent credential carries the key's owner as granted_by_user, never nil", layer: "request" }
    it "stamps the key's owner as the grantor of record" do
      collab = create_user(github_uid: "4010", github_handle: "collab")
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])

      post "/api/v1/repositories/#{repository.id}/members",
           params: { handle: collab.github_handle, permissions: ["view"] }.to_json,
           headers: bearer(key.raw_token).merge("Content-Type" => "application/json")

      membership = repository.repository_memberships.find_by(user: collab)
      expect(membership).to be_present
      expect(membership.granted_by_user).to eq(person)
    end

    # THE KEY'S OWN GRANT BOUND. The model's grantor bound measures the OWNER — who holds the
    # whole vocabulary — so without a second bound this key would widen itself: `members.manage`
    # in, `repo.delete` out. The refusal names the over-reach and nothing is written.
    # @intent: { entity: "AgentApiKey", action: "refuse an over-reaching grant", behavior: "a key holding only members.manage is refused when it grants repo.delete, with a message naming the permission", layer: "request" }
    it "refuses to grant a permission the key itself does not hold" do
      collab = create_user(github_uid: "4010", github_handle: "collab")
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])

      expect {
        post "/api/v1/repositories/#{repository.id}/members",
             params: { handle: collab.github_handle, permissions: ["repo.delete"] }.to_json,
             headers: bearer(key.raw_token).merge("Content-Type" => "application/json")
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("repo.delete")
      expect(response.parsed_body["message"]).to include("cannot grant it")
    end

    # The same refusal on its plural branch: TWO over-reaching permissions in one submission, so
    # the message renders the "them" reading — which a single-permission example never reaches —
    # and the list keeps the order the request submitted, pinning the intersection order nothing
    # else asserts.
    # @intent: { entity: "AgentApiKey", action: "refuse a multi-permission over-reaching grant", behavior: "a key holding only members.manage submitting two permissions it does not hold is refused with both named, in submitted order", layer: "request" }
    it "names both over-reaching permissions, in submitted order, when the grant over-reaches twice" do
      collab = create_user(github_uid: "4012", github_handle: "collab-two")
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])

      expect {
        post "/api/v1/repositories/#{repository.id}/members",
             params: { handle: collab.github_handle,
                       permissions: %w[keys.manage repo.delete] }.to_json,
             headers: bearer(key.raw_token).merge("Content-Type" => "application/json")
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("keys.manage, repo.delete")
      expect(response.parsed_body["message"]).to include("cannot grant them")
    end

    # THE GRANTOR BOUND IS LIVE, NOT FAIL-OPEN — and only a real, stamped grantor can prove it.
    # The mint-time bound does not follow the owner's rights afterwards, so a key can out-live
    # what its owner holds; when it does, the model bound must refuse. With a nil grantor the
    # validation would fail OPEN and this grant would succeed.
    # @intent: { entity: "AgentApiKey", action: "keep the grantor bound live", behavior: "a grant the key holds but its owner no longer does is refused by the model's grantor bound, proving the attribution is real", layer: "request" }
    it "refuses a grant its owner's narrowed rights no longer support" do
      collab = create_user(github_uid: "4010", github_handle: "collab")
      landlord = create_user(github_uid: "4011", github_handle: "repo-owner")
      shared = create_repository(user: landlord, github_full_name: "acme/shared-thing")
      owner_membership = create_membership(repository: shared, user: person,
                                           permissions: %w[members.manage repo.delete])
      key = create_agent_api_key(user: person, repositories: [shared],
                                 permissions: %w[members.manage repo.delete])
      # The owner's own rights narrow after the mint; the key deliberately does not.
      owner_membership.update!(permissions: %w[members.manage])

      expect {
        post "/api/v1/repositories/#{shared.id}/members",
             params: { handle: collab.github_handle, permissions: ["repo.delete"] }.to_json,
             headers: bearer(key.raw_token).merge("Content-Type" => "application/json")
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to include("the grantor does not hold")
    end

    # @intent: { entity: "AgentApiKey", action: "refuse an unpermitted add", behavior: "an in-set repository asked for a member add by a key without members.manage answers 403", layer: "request" }
    it "answers 403 without the members.manage permission" do
      collab = create_user(github_uid: "4010", github_handle: "collab")

      expect {
        post "/api/v1/repositories/#{repository.id}/members",
             params: { handle: collab.github_handle, permissions: ["view"] }.to_json,
             headers: bearer(agent_key.raw_token).merge("Content-Type" => "application/json")
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # @intent: { entity: "AgentApiKey", action: "hide the ungranted add", behavior: "a member add on a repository outside the key's set answers 404, even with members.manage held", layer: "request" }
    it "answers 404 for a repository outside the set, even holding members.manage" do
      collab = create_user(github_uid: "4010", github_handle: "collab")
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])

      post "/api/v1/repositories/#{other_repository.id}/members",
           params: { handle: collab.github_handle, permissions: ["view"] }.to_json,
           headers: bearer(key.raw_token).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/repositories/:repository_id/members/:id" do
    # Same gate, same bounds — and the re-stamp SPGD-117 §3 requires preserved identically under
    # the agent credential: every save re-names the current principal, so the trail never mixes
    # an earlier grantor into a later edit.
    # @intent: { entity: "AgentApiKey", action: "edit a member", behavior: "an agent key holding members.manage edits a member's permissions and re-stamps the grant to the key's owner", layer: "request" }
    it "edits a member's permissions and re-stamps the grant to the key's owner" do
      collab = create_user(github_uid: "4010", github_handle: "collab")
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])
      membership = create_membership(repository: repository, user: collab)

      patch "/api/v1/repositories/#{repository.id}/members/#{membership.id}",
            params: { permissions: %w[view members.manage] }.to_json,
            headers: bearer(key.raw_token).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(membership.reload.permissions).to eq(%w[view members.manage])
      expect(membership.reload.granted_by_user).to eq(person)
    end

    # The bound holds on the narrowing path's inverse: an edit that would HAND OUT what the key
    # does not hold is refused and the row keeps its stored permissions.
    # @intent: { entity: "AgentApiKey", action: "refuse an over-reaching edit", behavior: "an edit granting keys.manage by a key holding only members.manage answers 400 and leaves the row unchanged", layer: "request" }
    it "refuses an edit that would hand out a permission the key does not hold" do
      collab = create_user(github_uid: "4010", github_handle: "collab")
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])
      membership = create_membership(repository: repository, user: collab)

      patch "/api/v1/repositories/#{repository.id}/members/#{membership.id}",
            params: { permissions: ["keys.manage"] }.to_json,
            headers: bearer(key.raw_token).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:bad_request)
      expect(membership.reload.permissions).to eq([RepositoryMembership::VIEW])
    end
  end

  describe "DELETE /api/v1/repositories/:repository_id/members/:id" do
    # @intent: { entity: "AgentApiKey", action: "revoke a membership", behavior: "an agent key holding members.manage revokes a membership on a repository in its set", layer: "request" }
    it "revokes a membership for a key holding members.manage on a repository in the set" do
      collab = create_user(github_uid: "4010", github_handle: "collab")
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["members.manage"])
      membership = create_membership(repository: repository, user: collab)

      expect {
        delete "/api/v1/repositories/#{repository.id}/members/#{membership.id}",
               headers: bearer(key.raw_token)
      }.to change(RepositoryMembership, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end
  end

  describe "DELETE /api/v1/repositories/:id" do
    # The verb this route always gated on — `:repo_delete`, deliberately NOT `:owner` — is the
    # whole answer for the agent credential too: no person in the request, no person-shaped rule.
    # @intent: { entity: "AgentApiKey", action: "destroy a repository", behavior: "an agent key holding repo.delete destroys a repository in its set", layer: "request" }
    it "destroys the repository for a key holding repo.delete on a repository in its set" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["repo.delete"])

      expect {
        delete "/api/v1/repositories/#{repository.id}", headers: bearer(key.raw_token)
      }.to change(Repository, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    # @intent: { entity: "AgentApiKey", action: "refuse an unpermitted destroy", behavior: "an in-set repository asked for deletion by a key without repo.delete answers 403", layer: "request" }
    it "answers 403 without the repo.delete permission" do
      expect {
        delete "/api/v1/repositories/#{repository.id}", headers: bearer(agent_key.raw_token)
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # @intent: { entity: "AgentApiKey", action: "hide the ungranted destroy", behavior: "a deletion on a repository outside the key's set answers 404, even with repo.delete held", layer: "request" }
    it "answers 404 for a repository outside the set, even holding repo.delete" do
      key = create_agent_api_key(user: person, repositories: [repository],
                                 permissions: ["repo.delete"])

      delete "/api/v1/repositories/#{other_repository.id}", headers: bearer(key.raw_token)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the person-anchored verbs, which the agent credential never reaches" do
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

    # THE PERSON-SHAPED RESIDUE after SPGD-973. The token is valid and of a class the endpoint
    # accepts, so the refusal is 403 — "you may not", not "who are you?" — from
    # `require_person_credential`: registration redeems a GithubRegistrationGrant only a browser
    # session produced, and rename is `:owner`, which `AgentApiKeyPolicy#owner?` refuses by
    # construction.
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

    # SPGD-991 — the port of `ApiKey`'s evidence half (SPGD-804) to the third credential: the 401
    # itself is attributable because the row the digest names still exists, so the failure path
    # stamps it. A revoked token keeps arriving (decommissioned agents, leaked tokens) and the
    # owner watching the row on /account needs the date the platform last saw it.
    # @intent: { entity: "AgentApiKey", action: "attribute a refusal", behavior: "a revoked agent key presented again answers 401 AND stamps last_refused_at on the named row", layer: "request" }
    it "stamps last_refused_at on the revoked row it refuses" do
      token = agent_key.raw_token
      agent_key.revoke!

      expect {
        get "/api/v1/repositories", headers: bearer(token)
      }.to change { agent_key.reload.last_refused_at }.from(nil).to(be_present)

      expect(response).to have_http_status(:unauthorized)
    end

    # The honest half of the same claim: an UNKNOWN `sga_` token names no row — there is nothing
    # to attribute a refusal to, and nothing is synthesized for it (same rule as `ApiKey`'s seam).
    # @intent: { entity: "AgentApiKey", action: "not invent a refusal", behavior: "an unknown sga_ token answers 401, writes no row, and leaves every existing stamp untouched", layer: "request" }
    it "writes nothing for a token that never named a key" do
      agent_key.revoke!
      agent_key.touch_last_refused!

      expect {
        get "/api/v1/repositories", headers: bearer("sga_#{SecureRandom.urlsafe_base64(24)}")
      }.not_to change { agent_key.reload.last_refused_at }

      expect(response).to have_http_status(:unauthorized)
    end

    # The cost contract, held on the failure path the way "the cost of a valid presentation" holds
    # it on the success path. Two reads of the credential table, both on the unique digest index:
    # the resolving read EVERY presentation pays (a revoked token resolves to nil, the eager-loaded
    # owner riding the same statement), and the ONE read the failure path itself adds — the
    # `revoked_at IS NOT NULL AND token_digest = …` lookup — plus the stamp. No other credential
    # table is touched. The VALID presentation above is unchanged and still pinned by its examples.
    # @intent: { entity: "AgentApiKey", action: "attribute without probing", behavior: "the refused presentation costs resolution plus one revoked lookup on the digest index and one update, and no other credential table is read", layer: "request" }
    it "attributes the refusal with one indexed lookup and one stamp, nothing else" do
      token = agent_key.raw_token
      agent_key.revoke!

      statements = queries_against(/api_keys/) do
        get "/api/v1/repositories", headers: bearer(token)
      end

      expect(response).to have_http_status(:unauthorized)
      lookups = statements.grep(/FROM "agent_api_keys"/)
      expect(lookups.size).to eq(2)
      expect(lookups).to all(include("token_digest"))
      expect(lookups.count { |sql| sql.include?('"agent_api_keys"."revoked_at" IS NOT NULL') }).to eq(1)
      expect(statements.grep(/UPDATE "agent_api_keys"/).size).to eq(1)
      expect(statements.grep(/FROM "api_keys"/)).to be_empty
      expect(statements.grep(/FROM "user_api_keys"/)).to be_empty
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
