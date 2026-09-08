# frozen_string_literal: true

require "rails_helper"

# SPGD-754: the mutating half of the machine-facing repository surface — DELETE a repository,
# mint and revoke its `sgk_` keys — over a `sgu_` user key, plus the 404-vs-403 fork the shared
# `RepositoryAuthorization` concern carries into the API tree. SPGD-993 adds the inventory GET on
# the same gate: the read that makes the mint-and-replace recovery completable over the API alone.
#
# The fork is the point of the extraction and is asserted here rather than inferred:
#   - a caller who is NOT a member of the repository gets 404 and learns nothing of its existence;
#   - a member holding only `view` gets 403 — they can already see it, so 404 would be a lie.
# Both bodies are the API's own `{error:, message:}` JSON, not Rails' public-exception page — that
# distinction is why `Api::BaseController` registers the `rescue_from` pair at all.
RSpec.describe "API v1 — repository admin over a user key", type: :request do
  let(:owner) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: owner, github_full_name: "acme/billing-service") }
  let(:owner_key) { create_user_api_key(user: owner) }

  # A second identity who is a member of `repository` — the 403 half of the fork — and one who is
  # a stranger to it — the 404 half.
  let(:member) { create_user(github_uid: "9999", github_handle: "hubot") }
  let(:member_key) { create_user_api_key(user: member) }
  let(:stranger) { create_user(github_uid: "7777", github_handle: "locutus") }
  let(:stranger_key) { create_user_api_key(user: stranger) }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  def mint_path(repo = repository) = "/api/v1/repositories/#{repo.id}/api_keys"
  def revoke_path(key, repo = repository) = "/api/v1/repositories/#{repo.id}/api_keys/#{key.id}"

  # `token` held once in a local because `raw_token` is gone after a reload — the property the
  # reveal-once examples assert against the DATABASE, not the in-memory object.
  let!(:minted_response) do
    post mint_path, params: { name: "Second pipeline" }, headers: bearer(owner_key.raw_token)
    @minted_status = response.status
    response.parsed_body
  end

  describe "DELETE /api/v1/repositories/:id" do
    # @intent: { entity: "repository", action: "destroy for the owner", behavior: "the owner user key deletes the repository row and answers 204 with no body", layer: "request" }
    it "destroys the repository for the owner and answers 204" do
      expect {
        delete "/api/v1/repositories/#{repository.id}", headers: bearer(owner_key.raw_token)
      }.to change(Repository, :count).by(-1)

      expect(response).to have_http_status(:no_content)
      expect(Repository.exists?(repository.id)).to be(false)
    end

    # @intent: { entity: "repository", action: "destroy for a delete member", behavior: "a member granted repo.delete may destroy the repository, the same permission fork the web surface carries", layer: "request" }
    it "destroys the repository for a member granted repo.delete" do
      create_membership(repository: repository, user: member,
                        permissions: %w[view repo.delete])

      expect {
        delete "/api/v1/repositories/#{repository.id}", headers: bearer(member_key.raw_token)
      }.to change(Repository, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    # @intent: { entity: "repository", action: "refuse a view member", behavior: "a member holding only view is refused 403 with the api error JSON and the repository count is unchanged", layer: "request" }
    it "answers 403 JSON for a member with only view" do
      create_membership(repository: repository, user: member, permissions: %w[view])

      expect {
        delete "/api/v1/repositories/#{repository.id}", headers: bearer(member_key.raw_token)
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
      expect(response.media_type).to eq("application/json")
    end

    # @intent: { entity: "repository", action: "hide from a stranger", behavior: "a stranger is told 404 in JSON so the repository existence stays hidden rather than merely its contents", layer: "request" }
    it "answers 404 JSON for a non-member, hiding the repository" do
      expect {
        delete "/api/v1/repositories/#{repository.id}", headers: bearer(stranger_key.raw_token)
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("error" => "not_found")
      expect(response.media_type).to eq("application/json")
    end

    # @intent: { entity: "repository", action: "answer for an unknown id", behavior: "an id matching no repository at all answers 404 for the owner too", layer: "request" }
    it "answers 404 for an id that is no repository at all" do
      delete "/api/v1/repositories/999999", headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/repositories/:repository_id/api_keys" do
    # @intent: { entity: "api key", action: "mint and reveal once", behavior: "the mint answers 201 with the plaintext sgk token shown exactly once, the row persisting only a digest and the creating user attributed", layer: "request" }
    it "mints a key for the owner, reveals the token once, and attributes the minter" do
      token = minted_response.dig("api_key", "token")

      # The status was captured inside the `let!` that ran the POST — re-issuing it here would
      # mint a SECOND key and `repository.api_keys.last` below would name the wrong one.
      expect(@minted_status).to eq(201)
      expect(token).to be_present
      expect(token).to start_with(ApiKey::TOKEN_PREFIX)

      key = repository.api_keys.last
      expect(key.name).to eq("Second pipeline")
      expect(key.created_by_user).to eq(owner)
      # SPGD-993: the id rides the mint response — the caller's only durable handle on this row,
      # since the token below is reveal-once and the revoke names rows by it.
      expect(minted_response.dig("api_key", "id")).to eq(key.id)
      # Only the digest is persisted: reading the row back finds no column carrying the plaintext.
      expect(key.reload.token_digest).to be_present
      expect(key.token_hint).to eq(minted_response.dig("api_key", "hint"))
    end

    # @intent: { entity: "api key", action: "default the name", behavior: "minting without a name parameter stores and serves the model default name", layer: "request" }
    it "defaults the name when none is sent" do
      post mint_path, headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("api_key", "name")).to eq(ApiKey::DEFAULT_NAME)
    end

    # @intent: { entity: "api key", action: "mint for a member", behavior: "a member granted keys.manage mints successfully and the new key is attributed to that member", layer: "request" }
    it "mints for a member granted keys.manage, attributed to them" do
      create_membership(repository: repository, user: member, permissions: %w[view keys.manage])

      post mint_path, headers: bearer(member_key.raw_token)

      expect(response).to have_http_status(:created)
      expect(repository.api_keys.last.created_by_user).to eq(member)
    end

    # @intent: { entity: "api key", action: "refuse a view member", behavior: "a view-only member cannot mint and the api key count does not move", layer: "request" }
    it "answers 403 JSON for a member with only view" do
      create_membership(repository: repository, user: member, permissions: %w[view])

      expect {
        post mint_path, headers: bearer(member_key.raw_token)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
    end

    # @intent: { entity: "api key", action: "hide from a stranger", behavior: "a stranger cannot learn the mint endpoint exists, answering 404 with no key created", layer: "request" }
    it "answers 404 JSON for a non-member" do
      expect {
        post mint_path, headers: bearer(stranger_key.raw_token)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("error" => "not_found")
    end
  end

  describe "GET /api/v1/repositories/:repository_id/api_keys" do
    # SPGD-993 — the read half of this surface. The mint reveals its token once, the revoke names
    # a row by primary key, and until this endpoint nothing over the API served that id: a caller
    # could mint a replacement but could never identify the orphan to revoke. The browser key
    # table (`repositories/_api_keys`) answers to a session, so this list is the only inventory a
    # key-holder has.
    #
    # `minted_response` above has already minted "Second pipeline" into `repository` — the
    # inventory must account for it, and its `id` in the mint response is the same id this list
    # serves back.
    let!(:legacy_key) { repository.api_keys.create!(name: "Legacy") }

    # @intent: { entity: "api key", action: "list the inventory", behavior: "a keys.manage holder reads the repository's own keys in insertion order with id, hint, creator, last use, and live/revoked status per row", layer: "request" }
    it "lists the repository's keys with the fields a rotation needs" do
      get mint_path, headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body["api_keys"]
      # Insertion order (`order(:id)`), stable between calls: the minted key first, the later
      # fixture second.
      expect(rows.map { |r| r["id"] }).to eq([minted_response.dig("api_key", "id"), legacy_key.id])
      expect(rows.first.keys).to contain_exactly("id", "name", "token_hint", "created_at",
                                                 "created_by", "last_used_at", "status")
    end

    # @intent: { entity: "api key", action: "attribute a row", behavior: "an attributed key names its creator and its hint, a creator-less key renders the degraded Unknown, and no row ever carries a token", layer: "request" }
    it "serves the hint and creator per row, renders a nil creator as Unknown, and never a token" do
      get mint_path, headers: bearer(owner_key.raw_token)

      rows = response.parsed_body["api_keys"]
      minted_row = rows.find { |r| r["name"] == "Second pipeline" }
      expect(minted_row["created_by"]).to eq("octocat")
      expect(minted_row["token_hint"]).to eq(minted_response.dig("api_key", "hint"))
      expect(minted_row["last_used_at"]).to be_nil # never authenticated

      legacy_row = rows.find { |r| r["id"] == legacy_key.id }
      expect(legacy_row["created_by"]).to eq("Unknown")

      # The token is not among the served fields — under ANY spelling. Only the mint response
      # carried it, and only once.
      rows.each { |row| expect(row.keys).not_to include("token") }
    end

    # @intent: { entity: "api key", action: "serve a retired row", behavior: "a revoked key stays on the inventory as revoked with its stamp, and a live row carries no revoked_at key at all", layer: "request" }
    it "keeps a revoked row on the list as revoked, and omits revoked_at from a live row" do
      legacy_key.revoke!

      get mint_path, headers: bearer(owner_key.raw_token)

      revoked_row = response.parsed_body["api_keys"].find { |r| r["id"] == legacy_key.id }
      expect(revoked_row["status"]).to eq("revoked")
      expect(revoked_row["revoked_at"]).to be_present

      live_row = response.parsed_body["api_keys"].find { |r| r["status"] == "live" }
      expect(live_row.keys).not_to include("revoked_at")
    end

    # @intent: { entity: "api key", action: "scope the inventory", behavior: "the list serves only the named repository's keys — another repository's key ids never appear, even for their shared owner", layer: "request" }
    it "serves only the named repository's keys" do
      other = create_repository(user: owner, github_full_name: "acme/other-service")
      other.api_keys.create!(name: "Not yours")

      get mint_path, headers: bearer(owner_key.raw_token)

      ids = response.parsed_body["api_keys"].map { |r| r["id"] }
      expect(ids).to contain_exactly(minted_response.dig("api_key", "id"), legacy_key.id)
      expect(ids).not_to include(*other.api_keys.pluck(:id))
    end

    # @intent: { entity: "api key", action: "refuse a view member", behavior: "a view-only member cannot read the inventory and answers 403", layer: "request" }
    it "answers 403 JSON for a member with only view" do
      create_membership(repository: repository, user: member, permissions: %w[view])

      get mint_path, headers: bearer(member_key.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
    end

    # @intent: { entity: "api key", action: "hide the inventory from a stranger", behavior: "a non-member learns nothing of the repository or its keys, answering 404", layer: "request" }
    it "answers 404 JSON for a non-member" do
      get mint_path, headers: bearer(stranger_key.raw_token)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("error" => "not_found")
    end

    # THE TICKET'S OWN STORY, over the API alone and with no browser anywhere: the minted token
    # exists in plaintext for exactly one response, so the id in that response is the caller's
    # only durable handle on the row — mint, read the id, revoke by it, find the row retired.
    # @intent: { entity: "api key", action: "complete a rotation", behavior: "a caller mints, reads the id from the mint response, revokes that id, and finds the row revoked on the inventory — the whole recovery over the API alone", layer: "request" }
    it "completes mint-and-replace rotation over the API alone" do
      post mint_path, params: { name: "Replacement" }, headers: bearer(owner_key.raw_token)
      expect(response).to have_http_status(:created)
      id = response.parsed_body.dig("api_key", "id")
      expect(id).to be_present

      delete "/api/v1/repositories/#{repository.id}/api_keys/#{id}",
             headers: bearer(owner_key.raw_token)
      expect(response).to have_http_status(:no_content)

      get mint_path, headers: bearer(owner_key.raw_token)
      row = response.parsed_body["api_keys"].find { |r| r["id"] == id }
      expect(row["status"]).to eq("revoked")
      expect(row["revoked_at"]).to be_present
    end

    # THE N+1 GUARD, in the per-table budget discipline the credential-seam and overview specs
    # use: one SELECT against `api_keys` for the whole list and one against `users` for the
    # creators — `includes(:created_by_user)` doing its job — no matter how many rows. The
    # `FROM "…"` spellings are exact so the joined authentication statement (whose FROM names
    # `user_api_keys`) counts on neither side.
    # @intent: { entity: "api key", action: "read the list cheaply", behavior: "the inventory costs one api_keys select and one users select for the whole list, never one query per row", layer: "request" }
    it "pays one query per table for the whole list, not one per row" do
      repository.api_keys.create!(name: "Attributed", created_by_user: owner)
      token = owner_key.raw_token

      statements = queries_against(/api_keys|"users"/) do
        get mint_path, headers: bearer(token)
      end

      expect(response).to have_http_status(:ok)
      expect(statements.grep(/FROM "api_keys"/).size).to eq(1)
      expect(statements.grep(/FROM "users"/).size).to eq(1)
    end
  end

  describe "DELETE /api/v1/repositories/:repository_id/api_keys/:id" do
    let!(:ci_key) { repository.api_keys.create!(name: "CI") }

    # @intent: { entity: "api key", action: "revoke for the owner", behavior: "the owner revokes the named key and the row is retired (retained, stamped revoked_at) with a 204", layer: "request" }
    it "revokes the named key for the owner and answers 204" do
      revoked_token = ci_key.raw_token

      expect {
        delete revoke_path(ci_key), headers: bearer(owner_key.raw_token)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:no_content)
      # Retirement, not deletion (SPGD-804): the row survives, stamped — and the dead token stops
      # authenticating, asserted through `authenticate` because resolving a Bearer token is the
      # only thing the row's survival would actually mean.
      expect(ci_key.reload.revoked_at).to be_present
      expect(ApiKey.authenticate(revoked_token)).to be_nil
    end

    # @intent: { entity: "api key", action: "revoke for a member", behavior: "a member granted keys.manage retires a key just as the owner does, the row retained and stamped", layer: "request" }
    it "revokes for a member granted keys.manage" do
      create_membership(repository: repository, user: member, permissions: %w[view keys.manage])

      delete revoke_path(ci_key), headers: bearer(member_key.raw_token)

      expect(response).to have_http_status(:no_content)
      expect(ApiKey.exists?(ci_key.id)).to be(true)
      expect(ci_key.reload.revoked_at).to be_present
    end

    # @intent: { entity: "api key", action: "spare sibling keys", behavior: "revoking one key leaves the repository other keys still authenticating", layer: "request" }
    it "leaves the repository's other keys authenticating" do
      keeper = repository.api_keys.create!(name: "Prod")

      delete revoke_path(ci_key), headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:no_content)
      expect(ApiKey.authenticate(keeper.raw_token)).to eq(keeper)
    end

    # @intent: { entity: "api key", action: "refuse a foreign key", behavior: "a key belonging to a different repository answers 404 even for that repository owner, and survives", layer: "request" }
    it "answers 404 JSON for a key belonging to a different repository" do
      other = create_repository(user: owner, github_full_name: "acme/other-service")
      other_key = other.api_keys.create!(name: "Not yours")

      expect {
        delete revoke_path(other_key), headers: bearer(owner_key.raw_token)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("error" => "not_found")
    end

    # @intent: { entity: "api key", action: "refuse a view member", behavior: "a view-only member cannot revoke and the key count is unchanged", layer: "request" }
    it "answers 403 JSON for a member with only view" do
      create_membership(repository: repository, user: member, permissions: %w[view])

      expect {
        delete revoke_path(ci_key), headers: bearer(member_key.raw_token)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
    end

    # @intent: { entity: "api key", action: "hide from a stranger", behavior: "a stranger cannot revoke, answering 404 and leaving the key in place", layer: "request" }
    it "answers 404 JSON for a non-member" do
      expect {
        delete revoke_path(ci_key), headers: bearer(stranger_key.raw_token)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("error" => "not_found")
    end
  end

  describe "the credential seam, extended to the new routes" do
    let(:repository_key) { repository.api_keys.create! }

    # @intent: { entity: "credential seam", action: "refuse at destroy", behavior: "a repository key presented at the destroy route answers 401 and the repository survives", layer: "request" }
    it "refuses a repository key at DELETE /api/v1/repositories/:id with 401" do
      delete "/api/v1/repositories/#{repository.id}", headers: bearer(repository_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
      expect(repository.reload).to be_present
    end

    # @intent: { entity: "credential seam", action: "refuse at mint", behavior: "a repository key cannot mint keys, answering 401 with no row written", layer: "request" }
    it "refuses a repository key at the mint endpoint with 401" do
      # Resolved OUTSIDE the measured block, for the reason `credential_seam_spec.rb` states:
      # minting a key is itself a statement against `api_keys`, and a lazy `let` inside the block
      # would count it as the request's.
      token = repository_key.raw_token

      expect {
        post mint_path, headers: bearer(token)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    # @intent: { entity: "credential seam", action: "refuse at revoke", behavior: "a repository key cannot revoke keys, answering 401 and leaving the count unchanged", layer: "request" }
    it "refuses a repository key at the revoke endpoint with 401" do
      ci_key = repository.api_keys.create!(name: "CI")
      token = repository_key.raw_token

      expect {
        delete revoke_path(ci_key), headers: bearer(token)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
