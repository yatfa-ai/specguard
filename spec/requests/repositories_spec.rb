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
    # `find("table")` is unambiguous today: the API-keys table is the only one on this page. A
    # second table would raise Capybara::Ambiguous here, which is a loud failure, not a silent pass.
    def api_keys_table = Capybara.string(response.body).find("table")

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

    # The marker for a creator who no longer holds access. Its own describe rather than more
    # examples above, because every one of these needs the same two-people-and-a-revocation setup.
    describe "a key whose creator has since lost access" do
      # Counts the SELECTs a block issues, so "no per-row query" is asserted rather than eyeballed.
      # Schema reads and cached repeats are excluded: neither is work this page chose to do.
      def count_queries
        count = 0
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          count += 1 unless payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])
        end
        yield
        count
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # A colleague who minted a key and whose membership was then destroyed — reachable on main
      # today: MembershipsController#destroy touches no api_keys row, so the key outlives the
      # access it was minted under.
      def revoked_colleague(repository, handle:, uid:, key_name:)
        colleague = create_user(github_uid: uid, github_handle: handle)
        membership = create_membership(repository: repository, user: colleague,
                                       permissions: [RepositoryMembership::VIEW,
                                                     RepositoryMembership::KEYS_MANAGE])
        repository.api_keys.create!(name: key_name, created_by_user: colleague)
        membership.destroy!
        colleague
      end

      it "names the ex-colleague and marks the key their revoked access left behind" do
        repository = create_repository(user: @user)
        revoked_colleague(repository, handle: "revoked-dev", uid: "5005", key_name: "Their CI")

        get repository_path(repository)

        # The handle still has to be there — the marker is added to the attribution, not swapped
        # in for it. Without the handle the owner cannot tell *whose* key they are about to revoke.
        expect(api_key_row("Their CI")).to have_text("revoked-dev")
        expect(api_key_row("Their CI")).to have_text("no longer has access")
      end

      it "marks neither the owner's key, a current member's key, nor an unattributed one" do
        repository = create_repository(user: @user)
        current = create_user(github_uid: "6006", github_handle: "current-dev")
        create_membership(repository: repository, user: current,
                          permissions: [RepositoryMembership::VIEW, RepositoryMembership::KEYS_MANAGE])
        repository.api_keys.create!(name: "Owner CI", created_by_user: @user)
        repository.api_keys.create!(name: "Member CI", created_by_user: current)
        repository.api_keys.create!(name: "Legacy CI")

        get repository_path(repository)

        # Four creator states, and they must stay four. The owner holds access implicitly and has
        # no membership row, so reading the marker off "has a membership" alone would mark them.
        expect(api_key_row("Owner CI")).to have_no_text("no longer has access")
        expect(api_key_row("Member CI")).to have_no_text("no longer has access")
        # A NULL creator is a legacy key or a deleted account, never an ex-member — saying they
        # were revoked would be the page asserting something it does not know.
        expect(api_key_row("Legacy CI")).to have_text("Unknown")
        expect(api_key_row("Legacy CI")).to have_no_text("no longer has access")
      end

      it "asks about membership once for the whole table, not once per key" do
        repository = create_repository(user: @user)
        revoked_colleague(repository, handle: "revoked-dev", uid: "5005", key_name: "Their CI")

        get repository_path(repository)
        baseline = count_queries { get repository_path(repository) }

        # Distinct creators as well as more rows: a per-row membership lookup would grow with
        # either, and one that memoized per user would still grow with the second person.
        revoked_colleague(repository, handle: "other-dev", uid: "5006", key_name: "Other CI")
        3.times { |i| repository.api_keys.create!(name: "Owner CI #{i}", created_by_user: @user) }

        expect(count_queries { get repository_path(repository) }).to eq(baseline)
        expect(api_key_row("Other CI")).to have_text("no longer has access")
      end
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
