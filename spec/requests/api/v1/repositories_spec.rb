# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 — Bearer authentication", type: :request do
  let(:repository) { create_repository }
  let(:api_key) { repository.api_keys.create! }

  it "resolves the repository behind a valid Bearer key" do
    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("repository", "full_name")).to eq("acme/billing-service")
  end

  it "records when the key was last used" do
    expect(api_key.last_used_at).to be_nil

    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

    expect(api_key.reload.last_used_at).to be_present
  end

  it "rejects a bad key with 401" do
    get "/api/v1/repository", headers: { "Authorization" => "Bearer sgk_definitely-not-a-key" }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]).to eq("unauthorized")
  end

  it "rejects a missing Authorization header with 401" do
    get "/api/v1/repository"

    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects a non-Bearer scheme with 401" do
    get "/api/v1/repository", headers: { "Authorization" => "Basic #{api_key.raw_token}" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "scopes the response to the key's own repository" do
    other = create_repository(user: create_user(github_uid: "2002", github_handle: "hubot"),
                              github_full_name: "acme/ledger")
    other_key = other.api_keys.create!

    get "/api/v1/repository", headers: { "Authorization" => "Bearer #{other_key.raw_token}" }

    expect(response.parsed_body.dig("repository", "full_name")).to eq("acme/ledger")
  end
end
