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

    # ...but what the key is *for* must survive the flash, with a placeholder, never a secret.
    expect(response.body).to include("Connect this repository")
    expect(response.body).to include("&lt;token&gt;")
    expect(response.body).not_to match(/sgk_[A-Za-z0-9_-]{20,}/)
  end

  it "shows the endpoint and a copyable curl snippet with no flash present" do
    repository = create_repository(user: User.last)

    get repository_path(repository)

    expect(response.body).to include("Connect this repository")
    expect(response.body).to include("GET #{api_v1_repository_url}")
    expect(response.body).to include(%(curl -H "Authorization: Bearer &lt;token&gt;" #{api_v1_repository_url}))
  end

  it "reports 'not connected' while no API key has ever been used" do
    repository = create_repository(user: User.last)
    repository.api_keys.create!(name: "CI")

    get repository_path(repository)

    expect(repository.api_keys.maximum(:last_used_at)).to be_nil
    expect(response.body).to include("Not connected yet")
    expect(response.body).not_to include("Last request")
  end

  it "reports the last request once any API key has been used" do
    repository = create_repository(user: User.last)
    repository.api_keys.create!(name: "Idle")
    repository.api_keys.create!(name: "CI").touch_last_used!

    get repository_path(repository)

    expect(response.body).to match(/Last request .+ ago\./)
    expect(response.body).not_to include("Not connected yet")
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

  describe "renaming a repository" do
    it "updates the name without touching keys, runs or intents" do
      repository = create_repository(user: User.last, github_full_name: "acme/billing-servce")
      repository.api_keys.create!(name: "CI")
      repository.test_runs.create!(commit_sha: "a" * 40, branch: "main")
      create_spec_intent(repository: repository)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(response).to redirect_to(repository_path(repository))
      expect(repository.reload.github_full_name).to eq("acme/billing-service")

      # The entire point of the feature: renaming keeps everything the Remove workaround destroys.
      expect(repository.api_keys.count).to eq(1)
      expect(repository.test_runs.count).to eq(1)
      expect(repository.spec_intents.count).to eq(1)
    end

    it "re-derives the display name and normalizes a pasted GitHub URL" do
      repository = create_repository(user: User.last, github_full_name: "acme/old-name")

      patch repository_path(repository),
            params: { repository: { github_full_name: "https://github.com/acme/renamed.git" } }

      expect(repository.reload.github_full_name).to eq("acme/renamed")
      expect(repository.name).to eq("renamed")
    end

    it "re-renders the edit form when the new name is not org/repo" do
      repository = create_repository(user: User.last)

      patch repository_path(repository), params: { repository: { github_full_name: "nonsense" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must look like org/repo")
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    it "rejects a name already taken by another user rather than raising" do
      create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                        github_full_name: "other/repo")
      repository = create_repository(user: User.find_by(github_uid: "1001"))

      patch repository_path(repository), params: { repository: { github_full_name: "other/repo" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    it "accepts a save that leaves the name unchanged" do
      repository = create_repository(user: User.last)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(response).to redirect_to(repository_path(repository))
    end

    it "renders the edit form with a rename affordance on the repository page" do
      repository = create_repository(user: User.last)

      get repository_path(repository)
      expect(response.body).to include(edit_repository_path(repository))

      get edit_repository_path(repository)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="repository[github_full_name]"')
    end

    it "does not let a user rename another user's repository" do
      other = create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                                github_full_name: "other/repo")

      patch repository_path(other), params: { repository: { github_full_name: "acme/stolen" } }

      expect(response).to have_http_status(:not_found)
      expect(other.reload.github_full_name).to eq("other/repo")

      get edit_repository_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end
end
