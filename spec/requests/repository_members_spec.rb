# frozen_string_literal: true

require "rails_helper"

# Sharing slice 2b, the owner side: `/repositories/:repository_id/members` — list who has access,
# and take it away. This is the first production call site `members.manage` has ever had, so these
# examples are also the first proof that the permission decides anything at all.
#
# `sign_in_via_github(uid: ...)` drives the real OAuth callback, so calling it a second time
# *switches* the signed-in identity.
RSpec.describe "Repository members", type: :request do
  let(:owner) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: owner, github_full_name: "acme/billing-service") }
  let(:colleague) { create_user(github_uid: "9999", github_handle: "hubot") }

  describe "the owner" do
    before do
      repository
      sign_in_via_github
    end

    it "sees every member with their permission set" do
      create_membership(repository: repository, user: colleague, permissions: %w[view keys.manage])

      get repository_members_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("hubot")
      expect(response.body).to include("keys.manage")
    end

    # RepositoryMembership#user_is_not_the_owner makes an owner row impossible, so "the owner always
    # retains all permissions" holds structurally. This asserts the consequence rather than adding a
    # filter that would mask the invariant regressing — the same reasoning as the deliberate absence
    # of `.distinct` in RepositoriesController#index.
    it "does not see themselves in the list" do
      create_membership(repository: repository, user: colleague)

      get repository_members_path(repository)

      expect(response.body).to include("hubot")
      # The owner's own handle is in the topbar — they are signed in — so this has to be scoped to
      # the table: exactly one revoke control, and none of them aimed at the owner.
      expect(response.body.scan(%r{/repositories/#{repository.id}/members/\d+}).size).to eq(1)
      expect(response.body).not_to include("Revoke octocat")
    end

    # A blank table says "loading failed" as readily as "nobody has access"; and the reason the page
    # offers no Add control is worth stating on the page rather than only in the commit.
    it "sees an empty state naming that add-by-handle is not available yet, not a blank table" do
      get repository_members_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No one else has access")
      expect(response.body).to include("not available yet")
    end

    it "can revoke a member's access" do
      membership = create_membership(repository: repository, user: colleague)

      expect {
        delete repository_member_path(repository, membership)
      }.to change(RepositoryMembership, :count).by(-1)

      expect(response).to redirect_to(repository_members_path(repository))
    end
  end

  # Slice 2d. Revoking a membership removes only the *web* half of access: a member who held
  # `keys.manage` and minted a CI key keeps authenticating against the API afterwards, and that is
  # deliberate (`User has_many :created_api_keys, dependent: :nullify` — "an API key belongs to the
  # repository, not to whoever minted it"). These examples cover the two halves of that decision:
  # the owner-facing surfaces now *disclose* it, and the last example pins the behaviour itself so
  # it stays a decision rather than an accident.
  describe "the API keys a member minted" do
    let(:third_party) { create_user(github_uid: "8888", github_handle: "dependabot") }

    before do
      create_membership(repository: repository, user: colleague, permissions: %w[view keys.manage])
      create_membership(repository: repository, user: third_party, permissions: %w[view keys.manage])
      sign_in_via_github
    end

    # Every api_keys SELECT the members page issues. The page touches no other key data, so this is
    # exactly the count the badge costs — one grouped query for the whole table, never one per row.
    def api_key_queries
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        queries << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].to_s.include?("api_keys")
      end
      yield
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "shows each member's live key count, and asks for it in one grouped query" do
      repository.api_keys.create!(name: "CI — main", created_by_user: colleague)
      repository.api_keys.create!(name: "CI — release", created_by_user: colleague)
      repository.api_keys.create!(name: "Agent", created_by_user: third_party)

      queries = api_key_queries { get repository_members_path(repository) }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("2 API keys minted")
      expect(response.body).to include("1 API key minted")
      # Two members with keys, so a per-row count would be two queries and adding a third member
      # would make it three. This is the assertion that fails if the grouped query is unrolled.
      expect(queries.size).to eq(1)
    end

    it "counts only keys that are still live, so a revoked key stops being reported" do
      key = repository.api_keys.create!(name: "CI — main", created_by_user: colleague)
      repository.api_keys.create!(name: "CI — release", created_by_user: colleague)

      key.destroy!

      get repository_members_path(repository)

      expect(response.body).to include("1 API key minted")
      expect(response.body).not_to include("2 API keys minted")
    end

    # The count is scoped through `repository.api_keys`. A member who mints on two repositories must
    # not have the other repository's keys reported here — that would be a cross-tenant read on a
    # page whose whole subject is who can reach *this* repository.
    it "does not count keys the member minted on another repository" do
      other_repository = create_repository(user: owner, github_full_name: "acme/payments-service")
      other_repository.api_keys.create!(name: "Elsewhere", created_by_user: colleague)
      repository.api_keys.create!(name: "CI — main", created_by_user: colleague)

      get repository_members_path(repository)

      expect(response.body).to include("1 API key minted")
      expect(response.body).not_to include("2 API keys minted")
    end

    # A deep link is only useful if it lands. The badge points at `#api-keys`; the panel holding the
    # Revoke lever is what has to carry that id. Asserted from both ends in one example on purpose —
    # either half alone stays green while the link goes nowhere.
    it "points the badge at the API keys panel, which really carries that anchor" do
      repository.api_keys.create!(name: "CI — main", created_by_user: colleague)

      get repository_members_path(repository)
      expect(response.body).to include("#{repository_path(repository)}#api-keys")

      get repository_path(repository)
      expect(response.body).to include(%(id="api-keys"))
    end

    it "names the surviving keys in the revoke confirmation" do
      repository.api_keys.create!(name: "CI — main", created_by_user: colleague)
      repository.api_keys.create!(name: "CI — release", created_by_user: colleague)

      get repository_members_path(repository)

      expect(response.body).to include(
        "The 2 API keys they minted will keep authenticating until you revoke them."
      )
    end

    # The negative control for all of the above. Without it, rendering the badge and the extra
    # sentence unconditionally would still pass every example in this block.
    it "says nothing about keys for a member who minted none" do
      get repository_members_path(repository)

      expect(response.body).to include("hubot")
      # Matched as the badge's shape rather than the bare word "minted", which any future copy — or
      # a repository named `acme/minted-*` — could reintroduce, turning this control into a false
      # failure about something it was never asserting.
      expect(response.body).not_to match(/\d+ API keys? minted/)
      # The original one-sentence question, verbatim.
      expect(response.body).to include("Revoke hubot&#39;s access to acme/billing-service?")
      expect(response.body).not_to include("keep authenticating")
    end

    it "tells the owner the keys are still live after revoking the member" do
      repository.api_keys.create!(name: "CI — main", created_by_user: colleague)
      repository.api_keys.create!(name: "CI — release", created_by_user: colleague)
      membership = RepositoryMembership.find_by!(user: colleague, repository: repository)

      delete repository_member_path(repository, membership)

      expect(response).to redirect_to(repository_members_path(repository))
      expect(flash[:notice]).to eq(
        "Revoked hubot's access. 2 API keys they minted are still live — review them in the API keys panel."
      )
    end

    it "keeps the original notice when the revoked member minted nothing" do
      membership = RepositoryMembership.find_by!(user: colleague, repository: repository)

      delete repository_member_path(repository, membership)

      expect(flash[:notice]).to eq("Revoked hubot's access.")
    end

    # Both surfaces are built by string interpolation around a count, so the singular is a genuinely
    # separate code path — and "1 API keys ... are still live" is exactly the kind of sloppiness that
    # makes an owner trust the rest of the sentence less.
    it "reads correctly when the member minted exactly one key" do
      repository.api_keys.create!(name: "CI — main", created_by_user: colleague)
      membership = RepositoryMembership.find_by!(user: colleague, repository: repository)

      get repository_members_path(repository)
      expect(response.body).to include(
        "The 1 API key they minted will keep authenticating until you revoke it."
      )

      delete repository_member_path(repository, membership)
      expect(flash[:notice]).to eq(
        "Revoked hubot's access. 1 API key they minted is still live — review it in the API keys panel."
      )
    end

    # The behaviour every surface above exists to disclose, asserted end to end: revoking the web
    # half of access does NOT revoke the credential. If someone ever "fixes" this by switching
    # `created_api_keys` to `dependent: :destroy`, this example is what stops it — silently killing
    # the owner's green CI because a colleague changed teams is the worse failure.
    it "leaves the revoked member's key authenticating against the API" do
      key = repository.api_keys.create!(name: "CI — main", created_by_user: colleague)
      token = key.raw_token
      membership = RepositoryMembership.find_by!(user: colleague, repository: repository)

      delete repository_member_path(repository, membership)
      expect(RepositoryMembership.exists?(membership.id)).to be(false)

      get "/api/v1/repository", headers: { "Authorization" => "Bearer #{token}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("repository", "full_name")).to eq("acme/billing-service")
      # The key survived intact; only its attribution is at risk, and only if the *user* is deleted.
      expect(repository.api_keys.exists?(key.id)).to be(true)
    end
  end

  # `members.manage` and `keys.manage` are independent entries in RepositoryMembership::PERMISSIONS,
  # so this viewer is legitimate and reachable: they administer *who* can reach the repository and
  # hold no right whatsoever to its credential metadata. Every example above runs as the owner, who
  # holds both — which is why the whole block stays green whatever the disclosure is gated on. This
  # is the pair that can actually tell the difference.
  #
  # The rule being obeyed is already written down one controller over, in
  # `RepositoriesController#key_count_visible?`: repositories#show gates the entire API keys panel
  # behind `keys.manage`, "so a bare count on the card would leak past the same line". A count on
  # this page is the same count, and it must answer this viewer the same way.
  describe "the key count and the 'keys.manage' line" do
    let(:third_party) { create_user(github_uid: "8888", github_handle: "dependabot") }

    before do
      create_membership(repository: repository, user: third_party, permissions: %w[view keys.manage])
      repository.api_keys.create!(name: "CI — main", created_by_user: third_party)
      repository.api_keys.create!(name: "CI — release", created_by_user: third_party)
    end

    # The defect this block exists for: the viewer can revoke dependabot, and must be able to see
    # that dependabot is there — but "two credentials exist on this repository" is not theirs to
    # learn, on this page any more than on repositories#index.
    context "a viewer holding 'members.manage' but not 'keys.manage'" do
      before do
        create_membership(repository: repository, user: colleague, permissions: %w[view members.manage])
        sign_in_via_github(uid: "9999")
      end

      it "administers the member without being told how many keys exist" do
        get repository_members_path(repository)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("dependabot")
        expect(response.body).not_to match(/\d+ API keys? minted/)
      end

      # The same answer this viewer already gets one page over, asserted here so the two pages are
      # pinned to each other rather than merely happening to agree today. Matched against the
      # index's own badge copy — `pluralize(count, "key")`, not this page's "API key" — because a
      # regex borrowed from the members page would never match there and would pass vacuously.
      it "is refused the same count on the repositories index" do
        get repositories_path

        expect(response.body).to include("acme/billing-service")
        expect(response.body).not_to match(/\b\d+ keys?\b/)
      end

      it "sees the original confirm question, with no sentence about surviving keys" do
        get repository_members_path(repository)

        expect(response.body).to include("Revoke dependabot&#39;s access to acme/billing-service?")
        expect(response.body).not_to include("keep authenticating")
      end

      # The flash is an imperative, so leaking it here is worse than leaking the badge: it would
      # tell this viewer to go review keys in a panel they cannot open. They get today's copy.
      it "gets the original notice after revoking, not an instruction it cannot follow" do
        membership = RepositoryMembership.find_by!(user: third_party, repository: repository)

        delete repository_member_path(repository, membership)

        expect(flash[:notice]).to eq("Revoked dependabot's access.")
        expect(flash[:notice]).not_to include("API keys panel")
      end

      # What the badge promises has to exist at the other end of the link. It does not for this
      # viewer — which is the reason the badge is withheld rather than merely unlinked.
      it "cannot open the panel the badge would have pointed at" do
        get repository_path(repository)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(%(id="api-keys"))
      end
    end

    # The positive control, and the reason the gate is `can?(:keys_manage)` rather than `owner?`.
    # Without this example, restricting the disclosure to the owner would pass every assertion
    # above — a member who holds both permissions is entitled to the count and would silently
    # stop receiving it.
    context "a viewer holding both 'members.manage' and 'keys.manage'" do
      before do
        create_membership(repository: repository, user: colleague,
                          permissions: %w[view keys.manage members.manage])
        sign_in_via_github(uid: "9999")
      end

      it "sees the count, the confirm warning and the flash, exactly as the owner does" do
        get repository_members_path(repository)

        expect(response.body).to include("2 API keys minted")
        expect(response.body).to include(
          "The 2 API keys they minted will keep authenticating until you revoke them."
        )

        delete repository_member_path(repository, RepositoryMembership.find_by!(user: third_party,
                                                                               repository: repository))

        expect(flash[:notice]).to eq(
          "Revoked dependabot's access. 2 API keys they minted are still live — " \
          "review them in the API keys panel."
        )
      end

      # The badge's deep link, from this viewer's session: the panel and its anchor really are
      # reachable for anyone the badge is shown to.
      it "can open the panel the badge points at" do
        get repository_path(repository)

        expect(response.body).to include(%(id="api-keys"))
      end
    end
  end

  # The permission is not owner-only: the roadmap grants it "add/remove collaborators", so a
  # non-owner holder is legitimate and gets the same page.
  describe "a member holding 'members.manage'" do
    let(:third_party) { create_user(github_uid: "8888", github_handle: "dependabot") }

    before do
      create_membership(repository: repository, user: colleague, permissions: %w[view members.manage])
      create_membership(repository: repository, user: third_party, permissions: %w[view])
      sign_in_via_github(uid: "9999")
    end

    it "can open the members page" do
      get repository_members_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dependabot")
    end

    it "can revoke another member, whose access really is gone afterwards" do
      membership = RepositoryMembership.find_by!(user: third_party, repository: repository)

      expect {
        delete repository_member_path(repository, membership)
      }.to change(RepositoryMembership, :count).by(-1)

      # The revoked user is now a stranger to the repository: 404 on its own URL, absent from the
      # index. Anything less means the row went away but the access did not.
      sign_in_via_github(uid: "8888")

      get repository_path(repository)
      expect(response).to have_http_status(:not_found)

      get repositories_path
      expect(response.body).not_to include("acme/billing-service")
    end

    # Their own access is theirs to give up, and nothing guards it. They are then a stranger to the
    # members page, so the redirect has to go somewhere that still exists.
    it "can revoke themselves, and is redirected off the page they just lost" do
      own_membership = RepositoryMembership.find_by!(user: colleague, repository: repository)

      expect {
        delete repository_member_path(repository, own_membership)
      }.to change(RepositoryMembership, :count).by(-1)

      expect(response).to redirect_to(repositories_path)

      get repository_members_path(repository)
      expect(response).to have_http_status(:not_found)
    end
  end

  # The table names people — handles and avatars. That is the same category as the credential
  # metadata repositories#show already gates: the whole surface is refused, not just the button.
  describe "a member with only 'view'" do
    let!(:membership) { create_membership(repository: repository, user: colleague, permissions: %w[view]) }

    before { sign_in_via_github(uid: "9999") }

    it "gets 403 on the members page" do
      get repository_members_path(repository)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot revoke anyone" do
      expect {
        delete repository_member_path(repository, membership)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  # 404 rather than 403: the repository's existence stays hidden from a non-member, exactly as it
  # does on every other repository action.
  describe "a signed-in user with no membership" do
    let!(:membership) { create_membership(repository: repository, user: colleague) }

    before { sign_in_via_github(uid: "7777") }

    it "gets 404 on both actions, and revokes nothing" do
      get repository_members_path(repository)
      expect(response).to have_http_status(:not_found)

      expect {
        delete repository_member_path(repository, membership)
      }.not_to change(RepositoryMembership, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  # The IDOR this slice exists to not ship. On a nested member route `params[:id]` is a *membership*
  # id while `current_repository` authorized against `params[:repository_id]`, so a global
  # `RepositoryMembership.find` would authorize against repository A and then delete a row belonging
  # to repository B. The lookup must be scoped through the repository, as ApiKeysController#destroy
  # already scopes through `repository.api_keys`.
  describe "revoking across repositories" do
    it "refuses a membership id that belongs to a different repository" do
      other_owner = create_user(github_uid: "2002", github_handle: "other-owner")
      other_repository = create_repository(user: other_owner, github_full_name: "acme/payments-service")
      victim = create_membership(repository: other_repository,
                                 user: create_user(github_uid: "3003", github_handle: "victim"))

      create_membership(repository: repository, user: colleague, permissions: %w[view members.manage])
      sign_in_via_github(uid: "9999")

      expect {
        delete repository_member_path(repository, victim)
      }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:not_found)
      expect(RepositoryMembership.exists?(victim.id)).to be(true)
    end
  end

  describe "a signed-out visitor" do
    it "is sent to sign in rather than shown the list" do
      create_membership(repository: repository, user: colleague)

      get repository_members_path(repository)

      expect(response).to redirect_to(root_path)
    end
  end
end
