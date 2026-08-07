# frozen_string_literal: true

require "rails_helper"

# Slice 1 of repository sharing: authorization only. There is still no way to *grant* a membership
# through the UI — add-by-handle waits on `User.resolve_by_handle` — so memberships are created
# directly here and exercised over HTTP from the member's own session. The owner-side members page
# (list + revoke) has its own file: spec/requests/repository_members_spec.rb.
#
# `sign_in_via_github(uid: ...)` drives the real OAuth callback, so calling it a second time
# *switches* the signed-in identity — that is what makes these member-perspective specs, rather
# than the owner-perspective ones the existing suite already has.
RSpec.describe "Repository sharing", type: :request do
  let(:owner) { create_user(github_uid: "1001", github_handle: "octocat") }
  let(:repository) { create_repository(user: owner, github_full_name: "acme/billing-service") }

  # Signs in a second GitHub identity and shares `repository` with them.
  #
  # The member is given a handle of their own. `sign_in_via_github`'s mock defaults to the *owner's*
  # nickname, so without this override the member and the owner are two rows with the same name
  # (`github_handle` is deliberately not unique — see User) — and a surface asserted to name
  # "octocat" could be naming either of them. Overriding it is what makes the owner-identity
  # examples below prove which person the page named.
  def sign_in_as_member(permissions)
    member = sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
    create_membership(repository: repository, user: member, permissions: permissions)
  end

  # Captures the SQL a block issues, for the query-cost examples below to reduce however each one
  # needs. Schema reads and cached repeats are excluded: neither is work the page chose to do.
  # Each call site says in its own comment *why* it reduces the way it does — that reasoning is
  # per-example and belongs there, not here.
  def captured_sql
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      sql << payload[:sql].to_s unless payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])
    end
    yield
    sql
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "a member with only 'view'" do
    before { sign_in_as_member(%w[view]) }

    it "can open the shared repository" do
      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/billing-service")
    end

    # 403 rather than 404: they can already see the repository, so pretending it is missing lies.
    it "cannot mint an API key" do
      expect {
        post repository_api_keys_path(repository)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot revoke an existing API key" do
      api_key = repository.api_keys.create!(name: "CI")

      expect {
        delete repository_api_key_path(repository, api_key)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # Rename is owner-only for v1: `github_full_name` is the repository's identity and the global
    # unique key, and no membership permission covers it.
    it "cannot rename the repository" do
      patch repository_path(repository), params: { repository: { github_full_name: "acme/stolen" } }

      expect(response).to have_http_status(:forbidden)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")

      get edit_repository_path(repository)
      expect(response).to have_http_status(:forbidden)
    end

    it "cannot remove the repository" do
      expect {
        delete repository_path(repository)
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # Slice 1 listed only owned repositories, so a shared one was reachable by URL and on no page
    # the member could get to. Slice 2a is where that changes — this is slice 1's own tripwire,
    # inverted.
    it "sees the shared repository in their index, linking to it" do
      get repositories_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/billing-service")
      expect(response.body).to include(%(href="#{repository_path(repository)}"))
    end

    # Decision (a). Without it the member cannot tell a shared repository from one of their own,
    # and repositories#show offers a member holding `repo.delete` a destructive Remove on it.
    #
    # The badge names the *owner account* — the person to ask for a wider permission set. The
    # fixture makes that assertion load-bearing: the owner is @octocat and the slug's org segment is
    # `acme`, so a badge built from `github_full_name` reads "Shared · acme", which names a GitHub
    # org that may have two hundred members, none of whom can reach this repository.
    it "sees the owner's login on the shared card" do
      get repositories_path

      expect(response.body).to include("Shared · octocat")
      expect(response.body).not_to include("Shared · acme")
    end

    # The Overview panel states the same fact, and is held to the same rule. Anchored on the
    # `DefList` row rather than on a bare substring, because the org segment is also the first half
    # of the page title directly above it — so a substring match would pass on the title alone.
    # (The third surface, the Members empty state, is pinned in spec/requests/repository_members_spec.rb.)
    #
    # This couples a request spec to `DefListComponent`'s markup, knowingly. What it is pinning is
    # the *adjacency of the Owner row's label and its value* — that the panel names the owner in
    # the row labelled "Owner" — not the `dt`/`dd` tags themselves. So if this regex fails after a
    # change to the component while the panel still names the owner correctly, re-anchoring it on
    # whatever the component now renders is the right fix. Deleting it is not: the substring form
    # it would decay into passes on the page title and proves nothing.
    it "sees the owner named in the Overview panel, not the slug's org segment" do
      get repository_path(repository)

      expect(response.body).to match(%r{<dt[^>]*>\s*Owner\s*</dt>\s*<dd[^>]*>\s*octocat\s*</dd>}m)
      expect(response.body).not_to match(%r{<dt[^>]*>\s*Owner\s*</dt>\s*<dd[^>]*>\s*acme\s*</dd>}m)
    end

    # Decision (b). repositories#show gates every scrap of key metadata — names, hints, last-used —
    # behind `keys.manage`, so the card must not hand this member a key count the page it links to
    # would refuse them. The suite size is not credential information and stays.
    it "sees no key count on the shared card, but still sees the suite size" do
      repository.api_keys.create!(name: "CI")
      create_test_run(repository: repository, total_specs_count: 1234)

      get repositories_path

      expect(response.body).not_to include("1 key")
      expect(response.body).to include("1,234 tests")
    end

    # Decision (d). "Every repository you have registered" stopped being true the moment shared
    # repositories appeared in this list — the member registered none of them.
    it "sees a subtitle that admits the list is not all their own registrations" do
      get repositories_path

      expect(response.body).to include("shared with you")
      expect(response.body).not_to include("Every repository you have registered")
    end
  end

  describe "a member with 'keys.manage'" do
    before { sign_in_as_member(%w[view keys.manage]) }

    it "can create and revoke an API key on the shared repository" do
      expect {
        post repository_api_keys_path(repository)
      }.to change { repository.api_keys.count }.by(1)

      follow_redirect!
      expect(response.body).to match(/sgk_[A-Za-z0-9_-]{20,}/)

      expect {
        delete repository_api_key_path(repository, repository.api_keys.last)
      }.to change { repository.api_keys.count }.by(-1)
    end

    # The positive control for the suppression above: the key count is gated on the permission, not
    # on the card being shared. Without this, dropping the badge entirely would still pass.
    it "sees the key count on the shared card" do
      repository.api_keys.create!(name: "CI")

      get repositories_path

      expect(response.body).to include("1 key")
    end
  end

  describe "a member with 'repo.delete'" do
    before { sign_in_as_member(%w[view repo.delete]) }

    it "can remove the shared repository" do
      expect {
        delete repository_path(repository)
      }.to change(Repository, :count).by(-1)

      expect(response).to redirect_to(repositories_path)
    end
  end

  # Granting only `keys.manage` and not `view` is what a members UI checkbox grid will produce by
  # accident; the policy must not lock the member out of the page the keys live on.
  describe "a member granted a permission without an explicit 'view'" do
    before { sign_in_as_member(%w[keys.manage]) }

    it "can still open the repository" do
      get repository_path(repository)

      expect(response).to have_http_status(:ok)
    end
  end

  # The examples above prove every control *rejects* a member who lacks its permission. These prove
  # the control is never offered in the first place — a "Remove" button that asks a member to
  # confirm destroying the repository and all of its data, then dead-ends on a 403, is worse than
  # no button at all.
  describe "which controls repositories#show renders" do
    let!(:api_key) { repository.api_keys.create!(name: "CI") }

    # Each control, identified by a marker that only appears when it actually rendered.
    def rendered_controls
      {
        rename: response.body.include?(edit_repository_path(repository)),
        remove: response.body.include?("and all of its data?"),
        new_key: response.body.include?("New API key"),
        revoke: response.body.include?(repository_api_key_path(repository, api_key)),
        key_inventory: response.body.include?(api_key.token_hint),
        members: response.body.include?(repository_members_path(repository))
      }
    end

    # The positive control, and it is load-bearing: without it every `false` below would keep
    # passing if a label or a route were renamed out from under the markers.
    it "renders all of them for the owner" do
      repository
      sign_in_via_github

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(rendered_controls.values).to all(be(true))
    end

    it "renders none of them for a member with only 'view'" do
      sign_in_as_member(%w[view])

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/billing-service")
      expect(rendered_controls.values).to all(be(false))
    end

    # The whole API keys panel is gated, not just its two buttons: key names, token hints and
    # last-used timestamps are credential metadata, and nothing a member without `keys.manage` can
    # act on. The endpoint documentation and connection stat stay — see the comment in show.html.erb.
    it "renders the key controls, and only those, for a member with 'keys.manage'" do
      sign_in_as_member(%w[view keys.manage])

      get repository_path(repository)

      expect(rendered_controls).to eq(
        rename: false, remove: false, new_key: true, revoke: true, key_inventory: true, members: false
      )
    end

    it "renders remove, and only that, for a member with 'repo.delete'" do
      sign_in_as_member(%w[view repo.delete])

      get repository_path(repository)

      expect(rendered_controls).to eq(
        rename: false, remove: true, new_key: false, revoke: false, key_inventory: false, members: false
      )
    end
  end

  # Deliberately its own describe rather than a seventh key in `rendered_controls` above: that
  # matrix is for *controls*, things that 403 if they render ungated. This is a badge — it grants
  # nothing and 403s nowhere. What it discloses is who was removed from this repository, which is a
  # `members.manage` fact, so it is gated on `members.manage` even though the panel it sits in is
  # gated on `keys.manage`. That is MembershipsController#keys_minted_by's rule applied
  # symmetrically: the members page withholds a key count from a `members.manage`-only viewer, so
  # the keys panel withholds membership status from a `keys.manage`-only one. Both degrade to
  # silence rather than to a hedge.
  describe "the ex-member marker in the API keys panel" do
    let(:departed) { create_user(github_uid: "7777", github_handle: "departed-dev") }

    # Revoked, not merely never-a-member: the assertion only needs "does not currently hold
    # access", but the describe says *ex*-member, and a fixture that reaches that state the way
    # production does is the one a reader can trust. MembershipsController#destroy touches no
    # api_keys row, so the key outlives the access it was minted under.
    before do
      membership = create_membership(repository: repository, user: departed,
                                     permissions: [RepositoryMembership::VIEW,
                                                   RepositoryMembership::KEYS_MANAGE])
      repository.api_keys.create!(name: "Their CI", created_by_user: departed)
      membership.destroy!
    end

    it "is shown to the owner but withheld from a member holding 'keys.manage' and not 'members.manage'" do
      # The positive half is load-bearing: without it the negative below would keep passing if the
      # marker's wording changed, or if it stopped rendering for everyone.
      sign_in_via_github

      get repository_path(repository)

      expect(response.body).to include("no longer has access")

      # `sign_in_via_github` switches identity, so this is the same page seen by the other viewer.
      sign_in_as_member(%w[view keys.manage])

      get repository_path(repository)

      # They hold the panel — the withholding is of the membership fact, not of the row.
      expect(response.body).to include("Their CI").and include("departed-dev")
      expect(response.body).not_to include("no longer has access")
    end

    # The gate decides who may be *told*; this decides who has to *pay*. The keys panel is gated on
    # `keys.manage`, so a viewer holding `%w[view members.manage]` never renders it — and must not
    # be charged the membership query that feeds it. Asserted as a delta against a `view`-only
    # viewer, who cannot reach the marker at all: both skip the panel, so any extra query the
    # `members.manage` viewer issues is the lookup this page declined to render.
    #
    # Reduces to a total count: this example is a delta between two viewers of the same page, so
    # every query either of them issues is in scope.
    def count_queries(&) = captured_sql(&).size

    it "costs a 'members.manage' viewer who cannot see the panel no more than a 'view'-only one" do
      membership = sign_in_as_member(%w[view])
      get repository_path(repository)
      baseline = count_queries { get repository_path(repository) }

      # Same viewer, same repository, same rows, one more permission — and still no keys panel.
      membership.update!(permissions: %w[view members.manage])
      get repository_path(repository)

      expect(response.body).not_to include("Their CI")
      expect(count_queries { get repository_path(repository) }).to eq(baseline)
    end
  end

  # Naming the owner made the index ask a question *per card*, and the index is the one page that
  # renders many. `RepositoriesController#index` already states this discipline for its other
  # per-card question — `shared_permissions` is one query "whether the list has one shared card or
  # fifty" — so the new read is held to the same footing.
  describe "what naming the owner costs the index per shared card" do
    # Deliberately counts only reads of `users`, not every SELECT. The page has other per-card
    # queries that predate this (the intent count), so a total would be a moving target that fails
    # for reasons this example is not about, and would quietly encode those counts as intended.
    def user_table_queries(&) = captured_sql(&).grep(/from "users"/i).size

    it "reads the users table no more often for three shared cards than for one" do
      member = sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
      create_membership(repository: repository, user: member)

      get repositories_path
      baseline = user_table_queries { get repositories_path }

      # Each extra repository is owned by a *different* account, so a per-card `repository.user`
      # would be a distinct row — one that no identity map or query cache could serve for free.
      %w[2002 3003].each_with_index do |uid, index|
        other_owner = create_user(github_uid: uid, github_handle: "owner-#{index}")
        create_membership(repository: create_repository(user: other_owner,
                                                        github_full_name: "org#{index}/service"),
                          user: member)
      end

      get repositories_path

      # The positive control: without it this would keep passing if the badge stopped rendering.
      expect(response.body).to include("Shared · owner-0").and include("Shared · owner-1")
      expect(user_table_queries { get repositories_path }).to eq(baseline)
    end
  end

  describe "a signed-in user with no membership" do
    before do
      repository
      sign_in_via_github(uid: "8888")
    end

    # Existence stays hidden — the same shape as before sharing existed, when `current_repository`
    # scoped its `.find` to the signed-in user's own repositories.
    it "gets 404, not 403, on every repository action" do
      get repository_path(repository)
      expect(response).to have_http_status(:not_found)

      get edit_repository_path(repository)
      expect(response).to have_http_status(:not_found)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/stolen" } }
      expect(response).to have_http_status(:not_found)

      expect { post repository_api_keys_path(repository) }.not_to change(ApiKey, :count)
      expect(response).to have_http_status(:not_found)

      expect { delete repository_path(repository) }.not_to change(Repository, :count)
      expect(response).to have_http_status(:not_found)
    end

    # Existence stays hidden on the index too, not just on the record's own URL.
    it "sees an empty index rather than the repository" do
      get repositories_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("acme/billing-service")
      expect(response.body).to include("No repositories yet")
    end
  end

  describe "the owner" do
    # `repository` first: it creates the owner with uid 1001, which is the identity
    # `sign_in_via_github` then resolves to (User.from_github_omniauth upserts on the uid).
    before do
      repository
      sign_in_via_github
    end

    it "still does everything with no membership row of their own" do
      expect(RepositoryMembership.where(user: owner)).to be_empty

      get repository_path(repository)
      expect(response).to have_http_status(:ok)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/renamed" } }
      expect(repository.reload.github_full_name).to eq("acme/renamed")

      expect { post repository_api_keys_path(repository) }.to change(ApiKey, :count).by(1)
      expect { delete repository_path(repository) }.to change(Repository, :count).by(-1)
    end

    it "is unaffected by another user holding a membership" do
      create_membership(repository: repository, user: create_user(github_uid: "9999", github_handle: "someone-else"),
                        permissions: RepositoryMembership::PERMISSIONS)

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the owner's index" do
    before do
      repository
      sign_in_via_github
    end

    # The union must not double-count. It cannot today — RepositoryMembership rejects a row for the
    # owner — so this pins that invariant rather than a `.distinct` papering over its absence. Two
    # members, not one: a join-based union fans an owned repository out to one row *per* membership,
    # which a single membership row hides.
    it "lists an owned repository exactly once, however many members hold it" do
      %w[9999 8888].each_with_index do |uid, index|
        create_membership(repository: repository,
                          user: create_user(github_uid: uid, github_handle: "someone-else-#{index}"),
                          permissions: RepositoryMembership::PERMISSIONS)
      end

      get repositories_path

      expect(response.body.scan(%(href="#{repository_path(repository)}")).size).to eq(1)
    end

    # The other half of decision (a): the badge marks *shared*, so it must be absent when it isn't.
    it "renders no owner badge on a repository it owns" do
      get repositories_path

      expect(response.body).to include("acme/billing-service")
      expect(response.body).not_to include("Shared ·")
    end

    # The other half of decision (b): the owner holds every capability, so their card is unchanged.
    it "still sees both the key count and the suite size" do
      repository.api_keys.create!(name: "CI")
      create_test_run(repository: repository, total_specs_count: 1234)

      get repositories_path

      expect(response.body).to include("1 key")
      expect(response.body).to include("1,234 tests")
    end
  end

  # The index is a union of two sets, and its failure mode is an implementation that concatenates
  # them: `owned + shared` is an Array, so `.order` no longer applies and the page silently becomes
  # owned-then-shared. These two names are chosen so alphabetical and concatenated order disagree.
  describe "how the index orders owned and shared repositories" do
    it "sorts across both, rather than listing the owned one first" do
      member = sign_in_via_github(uid: "9999")
      create_repository(user: member, github_full_name: "zz/owned")
      create_membership(repository: create_repository(user: owner, github_full_name: "aa/shared"), user: member)

      get repositories_path

      expect(response.body).to include("zz/owned").and include("aa/shared")
      expect(response.body.index("aa/shared")).to be < response.body.index("zz/owned")
    end
  end
end
