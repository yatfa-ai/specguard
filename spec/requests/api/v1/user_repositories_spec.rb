# frozen_string_literal: true

require "rails_helper"

# SPGD-752 success criterion 2: a `sgu_` user key authenticates `GET /api/v1/repositories`, and the
# body lists exactly `Repository.accessible_by(user)`.
RSpec.describe "API v1 — GET /api/v1/repositories", type: :request do
  # The fixture the criterion names, and each third of it is load-bearing: OWNED and MEMBER are the
  # two halves of `accessible_by`'s union — a response built from either alone passes half the suite
  # — and INVISIBLE is the one that proves the list is not simply `Repository.all`.
  let(:person) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:stranger) { create_user(github_uid: "2002", github_handle: "hubot") }

  let!(:owned) { create_repository(user: person, github_full_name: "acme/billing-service") }
  let!(:shared) do
    create_repository(user: stranger, github_full_name: "acme/ledger").tap do |repository|
      create_membership(repository: repository, user: person)
    end
  end
  let!(:invisible) { create_repository(user: stranger, github_full_name: "acme/secret-payroll") }

  let(:user_api_key) { create_user_api_key(user: person) }

  def get_repositories(token: user_api_key.raw_token)
    get "/api/v1/repositories", headers: { "Authorization" => "Bearer #{token}" }
  end

  it "lists the repository the person owns and the one shared with them" do
    get_repositories

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repositories"].map { |row| row["full_name"] })
      .to eq(["acme/billing-service", "acme/ledger"])
  end

  # The half of the criterion that is about what is NOT there. Asserted against the whole serialized
  # body rather than against the name list alone, so a repository leaking through any other field —
  # an id, a `name` — is caught too.
  it "does not disclose a repository the person can neither open nor learn exists" do
    get_repositories

    expect(Repository.exists?(invisible.id)).to be(true)
    expect(response.body).not_to include("secret-payroll")
    expect(response.parsed_body["repositories"].map { |row| row["id"] }).not_to include(invisible.id)
  end

  # Not a restatement of the example above. That one asserts the OUTPUT; this asserts the RULE the
  # output came from, which is what the ticket requires — administration lands on the same policy
  # object the dashboard uses rather than on a parallel implementation. A hand-written
  # `where(user_id:)` would pass the first example and fail this one the day a third access path is
  # added to `accessible_by`.
  it "serves exactly `Repository.accessible_by`, not a second copy of the rule" do
    get_repositories

    expect(response.parsed_body["repositories"].map { |row| row["id"] })
      .to match_array(Repository.accessible_by(person).pluck(:id))
  end

  it "names which of the two access paths each row arrived by" do
    get_repositories

    roles = response.parsed_body["repositories"].to_h { |row| [row["full_name"], row["role"]] }

    expect(roles).to eq("acme/billing-service" => "owner", "acme/ledger" => "member")
  end

  it "answers an empty list — not a 404 — for somebody who can open nothing" do
    loner = create_user(github_uid: "3003", github_handle: "nobody")

    get_repositories(token: create_user_api_key(user: loner).raw_token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repositories"]).to eq([])
  end

  it "records when the key was last used" do
    expect(user_api_key.last_used_at).to be_nil

    get_repositories

    expect(user_api_key.reload.last_used_at).to be_present
  end

  it "rejects an unknown user token with 401" do
    get_repositories(token: "sgu_definitely-not-a-key")

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]).to eq("unauthorized")
  end

  it "rejects a missing Authorization header with 401" do
    get "/api/v1/repositories"

    expect(response).to have_http_status(:unauthorized)
  end
end
