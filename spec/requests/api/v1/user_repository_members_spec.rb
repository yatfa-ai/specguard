# frozen_string_literal: true

require "rails_helper"

# SPGD-875: member management over the `sgu_` surface — list, add by handle, edit permissions,
# revoke — as `Api::V1::UserRepositoryMembersController`, on the same `RepositoryAuthorization`
# seam and the same `RepositoryMembership` rules the web `MembershipsController` uses.
#
# What these examples pin, per the ticket's acceptance criteria:
#   - the 404/403 fork on every verb (non-member -> 404 hiding the repository; view-only
#     member -> 403);
#   - cross-repository scoping: a foreign membership id on PATCH/DELETE -> 404, other row intact;
#   - handle resolution: each non-`:found` answer is its own 400 sentence, and `:ambiguous`
#     creates nothing;
#   - the grantor bound: a `members.manage` holder cannot grant what they do not hold (4xx with
#     the model's error surfaced);
#   - `granted_by_user` is stamped server-side from the credential, never the request body;
#   - `permissions` array params persist intact (not silently dropped by a scalar permit);
#   - a `sgk_` repository key is refused 401 on all four routes;
#   - GET rows carry handle/permissions/granted_by/created_at ordered by handle, and no
#     `keys_minted`; GET and POST bodies carry the membership `id` PATCH/DELETE name rows by.
RSpec.describe "API v1 — repository members over a user key", type: :request do
  let(:owner) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: owner, github_full_name: "acme/billing-service") }
  let(:owner_key) { create_user_api_key(user: owner) }

  let!(:member) { create_user(github_uid: "9999", github_handle: "hubot") }
  let(:member_key) { create_user_api_key(user: member) }
  let!(:stranger) { create_user(github_uid: "7777", github_handle: "locutus") }
  let(:stranger_key) { create_user_api_key(user: stranger) }

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  def members_path(repo = repository) = "/api/v1/repositories/#{repo.id}/members"
  def member_path(id, repo = repository) = "/api/v1/repositories/#{repo.id}/members/#{id}"

  def post_member(handle:, permissions: [], token: owner_key.raw_token)
    post members_path,
         params: { handle: handle, permissions: permissions },
         headers: bearer(token)
  end

  describe "GET /api/v1/repositories/:repository_id/members" do
    let!(:grantor) { create_user(github_uid: "5555", github_handle: "grantor") }
    # `create_membership` has no `granted_by` kwarg (its callers never needed one), so the grantor
    # is stamped after the fact — `update_column`, because a plain `update!` would re-run the
    # grantor bound against a grantor who holds nothing on this repository (the factory's bare
    # grantors are not members) and refuse the row this example needs.
    let!(:first) do
      create_membership(repository: repository, user: member,
                        permissions: %w[view keys.manage]).tap { |row|
        row.update_column(:granted_by_user_id, grantor.id)
      }
    end
    let!(:second) do
      other = create_user(github_uid: "4444", github_handle: "alice")
      create_membership(repository: repository, user: other,
                        permissions: %w[view members.manage]).tap { |row|
        row.update_column(:granted_by_user_id, member.id)
      }
    end

    it "serves handle, permissions, granted_by handle and created_at per row, ordered by handle" do
      get members_path, headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body.fetch("members")
      expect(rows.map { |row| row.fetch("handle") }).to eq(%w[alice hubot])
      expect(rows.first).to include(
        "permissions" => %w[view members.manage],
        "granted_by" => "hubot"
      )
      expect(rows.first["created_at"]).to eq(second.created_at.iso8601)
      expect(rows.second["granted_by"]).to eq("grantor")
    end

    it "serves the membership id per row, so a caller can later edit or revoke what it lists" do
      get members_path, headers: bearer(owner_key.raw_token)

      rows = response.parsed_body.fetch("members")
      expect(rows.map { |row| row["id"] }).to eq([second.id, first.id])
    end

    it "does not disclose keys_minted" do
      get members_path, headers: bearer(owner_key.raw_token)

      expect(response.parsed_body.fetch("members").first).not_to have_key("keys_minted")
      expect(response.parsed_body.to_s).not_to include("keys_minted")
    end

    it "answers 403 for a member without members.manage" do
      get members_path, headers: bearer(member_key.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include("error" => "forbidden")
    end

    it "answers 404 for a non-member, hiding the repository" do
      get members_path, headers: bearer(stranger_key.raw_token)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("error" => "not_found")
    end
  end

  describe "POST /api/v1/repositories/:repository_id/members" do
    it "adds a resolved member, stamps the authenticated principal as grantor, and answers 201" do
      expect {
        post_member(handle: "hubot", permissions: %w[view keys.manage])
      }.to change(RepositoryMembership, :count).by(1)

      expect(response).to have_http_status(:created)
      row = repository.repository_memberships.find_by!(user: member)
      expect(row.permissions).to eq(%w[view keys.manage])
      expect(row.granted_by_user).to eq(owner)

      expect(response.parsed_body.fetch("member")).to include(
        "handle" => "hubot",
        "permissions" => %w[view keys.manage],
        "granted_by" => "octocat"
      )
    end

    it "serves the created membership's id, matching the persisted row" do
      post_member(handle: "hubot", permissions: %w[view])

      expect(response).to have_http_status(:created)
      row = repository.repository_memberships.find_by!(user: member)
      expect(response.parsed_body.fetch("member")).to include("id" => row.id)
    end

    it "stamps the grantor from the credential of a members.manage member, not just the owner" do
      create_membership(repository: repository, user: member,
                        permissions: %w[view members.manage])

      post_member(handle: "locutus", permissions: %w[view], token: member_key.raw_token)

      expect(response).to have_http_status(:created)
      expect(repository.repository_memberships.find_by!(user: stranger).granted_by_user)
        .to eq(member)
    end

    it "does not let the request body spoof the grantor" do
      post members_path,
           params: { handle: "hubot", permissions: %w[view],
                     granted_by_user_id: stranger.id, granted_by_user: stranger.id },
           headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:created)
      expect(repository.repository_memberships.find_by!(user: member).granted_by_user).to eq(owner)
    end

    it "persists the submitted permissions array intact, not silently dropped" do
      post_member(handle: "hubot", permissions: %w[view members.manage repo.delete])

      expect(response).to have_http_status(:created)
      expect(repository.repository_memberships.find_by!(user: member).permissions)
        .to eq(%w[view members.manage repo.delete])
    end

    it "refuses a member.grantor who does not hold every granted permission, surfacing the model error" do
      create_membership(repository: repository, user: member,
                        permissions: %w[view members.manage])

      post_member(handle: "locutus", permissions: %w[view repo.delete], token: member_key.raw_token)

      expect(response).to have_http_status(:bad_request)
      body = response.parsed_body
      expect(body.fetch("error")).to eq("bad_request")
      expect(body["message"]).to be_present
      expect(RepositoryMembership.exists?(repository: repository, user: stranger)).to be(false)
    end

    it "surfaces the model's own refusal for re-adding an existing member" do
      create_membership(repository: repository, user: member, permissions: %w[view])

      expect {
        post_member(handle: "hubot", permissions: %w[view])
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.fetch("details")).to include(
        /already has a membership on this repository/
      )
    end

    it "surfaces the model's own refusal for adding the owner" do
      expect {
        post_member(handle: "octocat", permissions: %w[view])
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.fetch("details")).to include(/already owns this repository/)
    end

    it "answers 400 with its own sentence for an ambiguous handle, creating nothing" do
      create_user(github_uid: "8881", github_handle: "recycled")
      create_user(github_uid: "8882", github_handle: "recycled")

      expect {
        post_member(handle: "recycled", permissions: %w[view])
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.fetch("message")).to include(
        "2 accounts share the handle recycled", "will not guess"
      )
    end

    it "answers 400 with its own sentence for a handle nobody has" do
      post_member(handle: "ghost", permissions: %w[view])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.fetch("message"))
        .to include("Nobody has signed into SpecGuard as ghost yet")
    end

    it "answers 400 with its own sentence for an archived handle" do
      departed = create_user(github_uid: "8883", github_handle: "departed")
      departed.update!(archived_at: Time.current)

      post_member(handle: "departed", permissions: %w[view])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.fetch("message")).to include(
        "account for departed has been archived"
      )
    end

    it "answers 400 with its own sentence for a malformed handle" do
      post_member(handle: "https://github.com/octocat", permissions: %w[view])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.fetch("message")).to include("That is not a GitHub handle")
    end

    it "answers 403 for a member without members.manage" do
      create_membership(repository: repository, user: member, permissions: %w[view])

      expect {
        post_member(handle: "locutus", permissions: %w[view], token: member_key.raw_token)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "answers 404 for a non-member" do
      expect {
        post_member(handle: "hubot", permissions: %w[view], token: stranger_key.raw_token)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/repositories/:repository_id/members/:id" do
    let!(:row) do
      create_membership(repository: repository, user: member,
                        permissions: %w[view keys.manage])
    end

    it "narrows the permissions, re-stamps the grantor, and serves the row" do
      patch member_path(row.id),
            params: { permissions: %w[view] },
            headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:ok)
      row.reload
      expect(row.permissions).to eq(%w[view])
      expect(row.granted_by_user).to eq(owner)
      expect(response.parsed_body.fetch("member")).to include(
        "handle" => "hubot", "permissions" => %w[view], "granted_by" => "octocat"
      )
    end

    it "re-stamps the grantor from the credential, ignoring a submitted grantor" do
      patch member_path(row.id),
            params: { permissions: %w[view], granted_by_user_id: stranger.id },
            headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:ok)
      expect(row.reload.granted_by_user).to eq(owner)
    end

    it "persists the submitted permissions array intact" do
      patch member_path(row.id),
            params: { permissions: %w[view members.manage] },
            headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:ok)
      expect(row.reload.permissions).to eq(%w[view members.manage])
    end

    it "refuses an escalation beyond the grantor's own rights, surfacing the model error" do
      create_membership(repository: repository, user: stranger,
                        permissions: %w[view members.manage])

      patch member_path(row.id),
            params: { permissions: %w[view repo.delete] },
            headers: bearer(stranger_key.raw_token)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.fetch("error")).to eq("bad_request")
      expect(row.reload.permissions).to eq(%w[view keys.manage])
    end

    it "answers 404 for a membership belonging to a different repository, leaving it untouched" do
      other = create_repository(user: owner, github_full_name: "acme/other-service")
      other_row = create_membership(repository: other, user: stranger, permissions: %w[view])

      expect {
        patch member_path(other_row.id),
              params: { permissions: %w[view members.manage] },
              headers: bearer(owner_key.raw_token)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:not_found)
      expect(other_row.reload.permissions).to eq(%w[view])
    end

    it "answers 404 for an id lifted from a DIFFERENT repository's own list, leaving it untouched" do
      other = create_repository(user: owner, github_full_name: "acme/other-service")
      other_row = create_membership(repository: other, user: stranger, permissions: %w[view])

      # The id is genuinely served to an authorized caller on the other repository — the exact
      # scenario the old comment feared — and naming it here must still 404, because
      # `find_membership!` scopes it away, not because the body withheld it.
      get members_path(other), headers: bearer(owner_key.raw_token)
      foreign_id = response.parsed_body.fetch("members").first.fetch("id")
      expect(foreign_id).to eq(other_row.id)

      patch member_path(foreign_id),
            params: { permissions: %w[view members.manage] },
            headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:not_found)
      expect(other_row.reload.permissions).to eq(%w[view])
    end

    it "answers 403 for a member without members.manage" do
      create_membership(repository: repository, user: stranger, permissions: %w[view])

      patch member_path(row.id),
            params: { permissions: %w[view] },
            headers: bearer(stranger_key.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(row.reload.permissions).to eq(%w[view keys.manage])
    end

    it "answers 404 for a non-member" do
      patch member_path(row.id),
            params: { permissions: %w[view] },
            headers: bearer(stranger_key.raw_token)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/repositories/:repository_id/members/:id" do
    let!(:row) do
      create_membership(repository: repository, user: member,
                        permissions: %w[view keys.manage])
    end

    it "revokes the membership and answers 204" do
      expect {
        delete member_path(row.id), headers: bearer(owner_key.raw_token)
      }.to change(RepositoryMembership, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "permits self-revocation by a members.manage holder, answering 204" do
      row.update!(permissions: %w[view members.manage])

      delete member_path(row.id), headers: bearer(member_key.raw_token)

      expect(response).to have_http_status(:no_content)
      expect(RepositoryMembership.exists?(row.id)).to be(false)
    end

    it "deliberately leaves the revoked member's minted CI keys authenticating" do
      repository.api_keys.create!(name: "hubot pipeline", created_by_user: member)

      delete member_path(row.id), headers: bearer(owner_key.raw_token)

      expect(response).to have_http_status(:no_content)
      expect(repository.api_keys.where(created_by_user: member)).to exist
    end

    it "answers 404 for a membership belonging to a different repository, leaving it untouched" do
      other = create_repository(user: owner, github_full_name: "acme/other-service")
      other_row = create_membership(repository: other, user: stranger, permissions: %w[view])

      expect {
        delete member_path(other_row.id), headers: bearer(owner_key.raw_token)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:not_found)
      expect(RepositoryMembership.exists?(other_row.id)).to be(true)
    end

    it "answers 403 for a member without members.manage" do
      create_membership(repository: repository, user: stranger, permissions: %w[view])

      delete member_path(row.id), headers: bearer(stranger_key.raw_token)

      expect(response).to have_http_status(:forbidden)
      expect(RepositoryMembership.exists?(row.id)).to be(true)
    end

    it "answers 404 for a non-member" do
      delete member_path(row.id), headers: bearer(stranger_key.raw_token)

      expect(response).to have_http_status(:not_found)
      expect(RepositoryMembership.exists?(row.id)).to be(true)
    end
  end

  describe "the credential seam, extended to the four member routes" do
    let(:repository_key) { repository.api_keys.create! }
    let!(:row) { create_membership(repository: repository, user: member, permissions: %w[view]) }

    it "refuses a repository key at GET with 401" do
      get members_path, headers: bearer(repository_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a repository key at POST with 401, creating nothing" do
      expect {
        post members_path,
             params: { handle: "locutus", permissions: %w[view] },
             headers: bearer(repository_key.raw_token)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a repository key at PATCH with 401" do
      patch member_path(row.id),
            params: { permissions: %w[view] },
            headers: bearer(repository_key.raw_token)

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a repository key at DELETE with 401" do
      expect {
        delete member_path(row.id), headers: bearer(repository_key.raw_token)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
