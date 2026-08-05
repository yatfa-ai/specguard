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

  it "offers a name field when minting a key, and shows when each key was created" do
    post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    repository = Repository.last
    repository.api_keys.create!(name: "Staging")

    get repository_path(repository)

    # The control must actually post a name — a bare button is what made every key identical.
    expect(response.body).to include('name="api_key[name]"')
    expect(response.body).to include("Created")
  end

  it "names a new API key from the form field" do
    post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    repository = Repository.last

    expect {
      post repository_api_keys_path(repository), params: { api_key: { name: "Staging" } }
    }.to change(ApiKey, :count).by(1)

    expect(ApiKey.last.name).to eq("Staging")

    # The chosen name is what makes the key distinguishable in the list and in the revoke confirm.
    follow_redirect!
    expect(response.body).to include("Staging")
  end

  it "falls back to the default name when the name field is left blank" do
    post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    repository = Repository.last

    post repository_api_keys_path(repository), params: { api_key: { name: "" } }

    expect(ApiKey.last.name).to eq("Default CI Key")
  end

  it "falls back to the default name when no params are sent at all" do
    post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    repository = Repository.last

    post repository_api_keys_path(repository)

    expect(ApiKey.last.name).to eq("Default CI Key")
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
