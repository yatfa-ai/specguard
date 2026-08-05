# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Repository registration and API keys", type: :request do
  before { sign_in_via_github }

  it "registers a GitHub repository for the signed-in user" do
    expect {
      post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    }.to change(Repository, :count).by(1)

    repository = Repository.last
    expect(repository.user).to eq(User.last)
    expect(response).to redirect_to(repository_path(repository))
  end

  it "re-renders the form when the name is not org/repo" do
    post repositories_path, params: { repository: { github_full_name: "nonsense" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("must look like org/repo")
  end

  it "shows a newly created API key exactly once" do
    post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    repository = Repository.last

    post repository_api_keys_path(repository)
    follow_redirect!

    raw_token = response.body[/sgk_[A-Za-z0-9_-]{20,}/]
    expect(raw_token).to be_present
    # The value shown is the real credential, and the digest of it is what was stored.
    expect(ApiKey.last.token_digest).to eq(ApiKey.digest(raw_token))
    expect(response.body).not_to include(ApiKey.last.token_digest)

    # A plain reload must not show it again — the value only ever lived in the flash.
    get repository_path(repository)
    expect(response.body).not_to include(raw_token)
  end

  it "revokes an API key" do
    post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    repository = Repository.last
    post repository_api_keys_path(repository)
    api_key = ApiKey.last

    expect {
      delete repository_api_key_path(repository, api_key)
    }.to change(ApiKey, :count).by(-1)
  end

  it "does not expose another user's repository" do
    other = create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                              github_full_name: "other/repo")

    get repository_path(other)

    expect(response).to have_http_status(:not_found)
  end
end
