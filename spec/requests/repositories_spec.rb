# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Repository registration and API keys", type: :request do
  before { @user = sign_in_via_github }

  it "registers a GitHub repository for the signed-in user" do
    expect {
      post repositories_path, params: { repository: { github_full_name: "acme/billing-service" } }
    }.to change(Repository, :count).by(1)

    repository = Repository.last
    expect(repository.user).to eq(@user)
    expect(response).to redirect_to(repository_path(repository))
  end

  it "re-renders the form when the name is not org/repo" do
    post repositories_path, params: { repository: { github_full_name: "nonsense" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("must look like org/repo")
  end

  it "shows a newly created API key exactly once" do
    repository = register_repository

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
    repository = create_repository(user: @user)

    get repository_path(repository)

    expect(response.body).to include("Connect this repository")
    expect(response.body).to include("GET #{api_v1_repository_url}")
    expect(response.body).to include(%(curl -H "Authorization: Bearer &lt;token&gt;" #{api_v1_repository_url}))
  end

  it "reports 'not connected' while no API key has ever been used" do
    repository = create_repository(user: @user)
    repository.api_keys.create!(name: "CI")

    get repository_path(repository)

    expect(repository.api_keys.maximum(:last_used_at)).to be_nil
    expect(response.body).to include("Not connected yet")
    expect(response.body).not_to include("Last request")
  end

  it "reports the last request once any API key has been used" do
    repository = create_repository(user: @user)
    repository.api_keys.create!(name: "Idle")
    repository.api_keys.create!(name: "CI").touch_last_used!

    get repository_path(repository)

    expect(response.body).to match(/Last request .+ ago\./)
    expect(response.body).not_to include("Not connected yet")
  end

  it "offers a name field when minting a key, and shows when each key was created" do
    repository = register_repository
    repository.api_keys.create!(name: "Staging")

    get repository_path(repository)

    # The control must actually post a name — a bare button is what made every key identical.
    expect(response.body).to include('name="api_key[name]"')
    expect(response.body).to include("Created")
  end

  it "names a new API key from the form field" do
    repository = register_repository

    expect {
      post repository_api_keys_path(repository), params: { api_key: { name: "Staging" } }
    }.to change(ApiKey, :count).by(1)

    expect(ApiKey.last.name).to eq("Staging")

    # The chosen name is what makes the key distinguishable in the list and in the revoke confirm.
    follow_redirect!
    expect(response.body).to include("Staging")
  end

  it "falls back to the default name when the name field is left blank" do
    repository = register_repository

    post repository_api_keys_path(repository), params: { api_key: { name: "" } }

    expect(ApiKey.last.name).to eq("Default CI Key")
  end

  it "falls back to the default name when no params are sent at all" do
    repository = register_repository

    post repository_api_keys_path(repository)

    expect(ApiKey.last.name).to eq("Default CI Key")
  end

  it "revokes an API key" do
    repository = register_repository
    post repository_api_keys_path(repository)
    api_key = ApiKey.last

    expect {
      delete repository_api_key_path(repository, api_key)
    }.to change(ApiKey, :count).by(-1)
  end

  describe "recording who minted a key" do
    # These read the parsed DOM rather than the raw body, because both of the obvious
    # whole-document assertions are unsound on this page:
    #
    #   * `include(@user.display_name)` is satisfied by the topbar, which prints
    #     `current_user.display_name` on every page (layouts/_topbar.html.erb:13) — so it passes
    #     with the creator cell deleted.
    #   * `include("Created")` is satisfied by the "Created by" header — so it passes with the
    #     pre-existing timestamp column deleted.
    #
    # Scoping to the key's own row and to the header cells makes both assertions load-bearing.
    # Scoped to `#api-keys` because this page now renders a second table (Recent runs) — a bare
    # `find("table")` would raise Capybara::Ambiguous. The `id` is the API-keys panel's own
    # deep-link anchor (repositories/show.html.erb), not something added for this finder.
    def api_keys_table = Capybara.string(response.body).find("#api-keys table")

    def api_key_headers = api_keys_table.all("thead th").map(&:text)

    def api_key_row(name) = api_keys_table.find("tbody tr", text: name)

    it "attributes a newly minted key to the signed-in user" do
      repository = register_repository

      post repository_api_keys_path(repository), params: { api_key: { name: "Staging" } }

      # Revoking is a hard delete with no audit row, so attribution recorded here is the only
      # attribution there will ever be.
      expect(ApiKey.last.created_by_user).to eq(@user)
    end

    it "names the colleague who minted a key on the owner's page" do
      # The scenario this slice exists for: a collaborator holding `keys.manage` mints a Bearer
      # credential on someone else's repository, and the owner has to be able to tell which key
      # is theirs before revoking anything.
      repository = create_repository(user: @user)
      colleague = create_user(github_uid: "4004", github_handle: "departing-dev")
      create_membership(repository: repository, user: colleague,
                        permissions: [RepositoryMembership::VIEW, RepositoryMembership::KEYS_MANAGE])
      repository.api_keys.create!(name: "Shared CI", created_by_user: colleague)

      get repository_path(repository)

      # Deliberately *not* the signed-in user's own handle — that one is in the topbar regardless.
      expect(api_key_row("Shared CI")).to have_text("departing-dev")
    end

    it "renders a fallback for a key with no recorded creator" do
      repository = create_repository(user: @user)
      repository.api_keys.create!(name: "Legacy CI")

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      # The rest of the row must be unaffected by the missing attribution.
      expect(api_key_row("Legacy CI")).to have_text("Unknown").and have_text("Revoke")
    end

    it "adds the creator column without disturbing the existing key columns" do
      repository = create_repository(user: @user)
      repository.api_keys.create!(name: "CI", created_by_user: @user).touch_last_used!

      get repository_path(repository)

      # Exact and ordered, so "Created by" cannot stand in for "Created". The trailing "" is the
      # Revoke button's unlabelled column.
      expect(api_key_headers).to eq(["Name", "Key", "Created by", "Created", "Last used", ""])
      expect(api_key_row("CI")).to have_text(ApiKey.last.token_hint)
    end
  end

  it "does not expose another user's repository" do
    other = create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                              github_full_name: "other/repo")

    get repository_path(other)

    expect(response).to have_http_status(:not_found)
  end

  describe "the Overview panel's suite figures" do
    # Scoped to the panel rather than the whole document, because the page is full of numbers and
    # prose that would satisfy a bare `response.body` match. `#overview` is the panel's own id.
    def overview_panel = Capybara.string(response.body).find("#overview")

    it "shows the suite denominator and the tests SpecGuard cannot see" do
      repository = create_repository(user: @user)
      # 3 specs, 2 annotated — so 1 test is invisible to SpecGuard, and 66.7% is the ratio.
      repository.test_runs.create!(commit_sha: "feedfacecafe0001", branch: "main",
                                   total_specs_count: 3, annotated_specs_count: 2)

      get repository_path(repository)

      panel = overview_panel
      # The denominator, which was stored and API-returned but rendered nowhere before this.
      expect(panel).to have_text("Tests in suite 3", normalize_ws: true)
      expect(panel).to have_text("Carrying an @intent 2", normalize_ws: true)
      # The number the whole panel exists for: what SpecGuard *cannot* see.
      expect(panel).to have_text("Not visible to SpecGuard 1", normalize_ws: true)
      # ...and the ratio never appears without the denominator it was computed over.
      expect(panel).to have_text("66.7% — 2 of 3 tests carry an @intent.", normalize_ws: true)
      expect(panel).to have_text("SpecGuard cannot see the other 1 test.", normalize_ws: true)
    end

    it "puts the real counts into the meter's accessible markup, not (ratio, 100)" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0002", total_specs_count: 3,
                                   annotated_specs_count: 2)

      get repository_path(repository)

      # `aria-valuemax="100"` would mean the component was handed the percentage and the suite size
      # never reached the accessibility tree — the same omission, one layer down.
      meter = overview_panel.find("[role='meter']")
      expect(meter["aria-valuemax"]).to eq("3.0")
      expect(meter["aria-valuenow"]).to eq("2.0")
    end

    it "names the run the figures were measured on" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0003", branch: "release/2.1",
                                   total_specs_count: 3, annotated_specs_count: 2)

      get repository_path(repository)

      # A stale run is a stale denominator, so the reader has to be able to see which run it is.
      expect(overview_panel).to have_text("Measured on feedfac (release/2.1)", normalize_ws: true)
    end

    it "reads the newest run, not the first one ingested" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "0ld", total_specs_count: 100, annotated_specs_count: 1)
      repository.test_runs.create!(commit_sha: "new", total_specs_count: 3, annotated_specs_count: 2)

      get repository_path(repository)

      expect(overview_panel).to have_text("Tests in suite 3", normalize_ws: true)
      expect(overview_panel).not_to have_text("Tests in suite 100", normalize_ws: true)
    end

    it "shows an empty state — never 0% — for a repository whose CI has never reported" do
      repository = create_repository(user: @user)

      get repository_path(repository)

      panel = overview_panel
      expect(panel).to have_text("No CI run has reported yet", normalize_ws: true)
      # The defect this replaces: never-ingested rendered byte-identically to measured-zero.
      expect(panel).to have_no_text("0%", normalize_ws: true)
      expect(panel).to have_no_css("[role='meter']")
    end

    it "distinguishes a run that measured zero annotations from one that never happened" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0004", total_specs_count: 3,
                                   annotated_specs_count: 0)

      get repository_path(repository)

      panel = overview_panel
      # This repository genuinely has 0% — and says so with its denominator attached.
      expect(panel).to have_text("0.0% — 0 of 3 tests carry an @intent.", normalize_ws: true)
      expect(panel).to have_text("SpecGuard cannot see the other 3 tests.", normalize_ws: true)
      expect(panel).to have_no_text("No CI run has reported yet", normalize_ws: true)
    end

    it "says so when the run itself reported no tests, rather than showing a vacuous 0%" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0005", total_specs_count: 0,
                                   annotated_specs_count: 0)

      get repository_path(repository)

      # 0/0 divides into a tidy 0% that reads exactly like "a suite with no annotations", so the
      # meter is suppressed here the same way it is for a never-ingested repo — asserting the
      # absence, not just the presence of the sentence that explains it.
      panel = overview_panel
      expect(panel).to have_text("reported no tests at all", normalize_ws: true)
      expect(panel).to have_no_text("0%", normalize_ws: true)
      expect(panel).to have_no_css("[role='meter']")
      # ...while the counts themselves still render: "the run measured nothing" is a fact worth
      # stating, and it is not the same as "no run has reported".
      expect(panel).to have_text("Tests in suite 0", normalize_ws: true)
      expect(panel).to have_no_text("No CI run has reported yet", normalize_ws: true)
    end

    it "labels the spec-intent count as a search index, not as a share of the suite" do
      repository = create_repository(user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0006", total_specs_count: 3,
                                   annotated_specs_count: 2)

      get repository_path(repository)

      # Ingestion writes no spec_intents row yet, so this is structurally 0 — and a bare
      # "Spec intents: 0" sitting above "Annotated: 66.7%" was two contradictory descriptions of
      # the same suite.
      panel = overview_panel
      expect(panel).to have_text("Searchable intents 0", normalize_ws: true)
      expect(panel).to have_text("not a count of tests in the suite", normalize_ws: true)
      expect(panel).to have_no_text("Spec intents", normalize_ws: true)
    end

    it "stays visible to a member who cannot manage keys" do
      owner = create_user(github_uid: "7007", github_handle: "repo-owner")
      repository = create_repository(user: owner, github_full_name: "acme/shared-service")
      create_membership(repository: repository, user: @user)
      repository.test_runs.create!(commit_sha: "feedfacecafe0007", total_specs_count: 3,
                                   annotated_specs_count: 2)

      get repository_path(repository)

      # Suite coverage is the same class of information as the connection-health stat: a `view`
      # member needs it, and none of it is credential metadata.
      expect(overview_panel).to have_text("Not visible to SpecGuard 1", normalize_ws: true)
      expect(response.body).not_to include("api-keys")
    end
  end

  describe "renaming a repository" do
    it "updates the name without touching keys, runs or intents" do
      repository = create_repository(user: @user, github_full_name: "acme/billing-servce")
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
      repository = create_repository(user: @user, github_full_name: "acme/old-name")

      patch repository_path(repository),
            params: { repository: { github_full_name: "https://github.com/acme/renamed.git" } }

      expect(repository.reload.github_full_name).to eq("acme/renamed")
      expect(repository.name).to eq("renamed")
    end

    it "re-renders the edit form when the new name is not org/repo" do
      repository = create_repository(user: @user)

      patch repository_path(repository), params: { repository: { github_full_name: "nonsense" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must look like org/repo")
      expect(repository.reload.github_full_name).to eq("acme/billing-service")

      # The rejected input belongs in the form field only. The breadcrumb and title identify
      # the record, so they must still name the repository as it is actually stored.
      expect(response.body).to include("acme/billing-service")
    end

    it "rejects a name already taken by another user rather than raising" do
      create_repository(user: create_user(github_uid: "9999", github_handle: "someone-else"),
                        github_full_name: "other/repo")
      repository = create_repository(user: @user)

      patch repository_path(repository), params: { repository: { github_full_name: "other/repo" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")
    end

    it "accepts a save that leaves the name unchanged" do
      repository = create_repository(user: @user)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(response).to redirect_to(repository_path(repository))
      expect(flash[:notice]).not_to include("Renamed")
    end

    it "confirms the rename in the flash when the name actually changed" do
      repository = create_repository(user: @user, github_full_name: "acme/billing-servce")

      patch repository_path(repository), params: { repository: { github_full_name: "acme/billing-service" } }

      expect(flash[:notice]).to eq("Renamed to acme/billing-service.")
    end

    it "links to the rename form from the repository page" do
      repository = create_repository(user: @user)

      get repository_path(repository)

      expect(response.body).to include(edit_repository_path(repository))
    end

    it "renders the rename form" do
      repository = create_repository(user: @user)

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
