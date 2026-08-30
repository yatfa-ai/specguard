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

  # `executed_sql` / `count_queries` come from spec/support/query_capture.rb, and capture the SQL a
  # block issues for the query-cost examples below to reduce however each one needs. Schema reads
  # and cached repeats are excluded there: neither is work the page chose to do. Each call site says
  # in its own comment *why* it reduces the way it does — that reasoning is per-example.

  describe "a member with only 'view'" do
    before { sign_in_as_member(%w[view]) }

    # @intent: {"entity": "RepositoryMembership", "action": "open shared repository", "behavior": "a member holding only view gets 200 on the repository page with the shared acme/billing-service slug in the body", "layer": "request"}
    it "can open the shared repository" do
      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/billing-service")
    end

    # 403 rather than 404: they can already see the repository, so pretending it is missing lies.
    # @intent: {"entity": "RepositoryMembership", "action": "refuse key minting", "behavior": "POST /repositories/:id/api_keys answers 403 and creates no ApiKey row for a view-only member", "layer": "request"}
    it "cannot mint an API key" do
      expect {
        post repository_api_keys_path(repository)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # @intent: {"entity": "RepositoryMembership", "action": "refuse key revocation", "behavior": "DELETE on an existing API key answers 403 and leaves the ApiKey count unchanged for a view-only member", "layer": "request"}
    it "cannot revoke an existing API key" do
      api_key = repository.api_keys.create!(name: "CI")

      expect {
        delete repository_api_key_path(repository, api_key)
      }.not_to change(ApiKey, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # Rename is owner-only for v1: `github_full_name` is the repository's identity and the global
    # unique key, and no membership permission covers it.
    # @intent: {"entity": "RepositoryMembership", "action": "refuse rename", "behavior": "PATCH /repositories/:id answers 403 leaving github_full_name at acme/billing-service, and GET edit is 403 as well", "layer": "request"}
    it "cannot rename the repository" do
      patch repository_path(repository), params: { repository: { github_full_name: "acme/stolen" } }

      expect(response).to have_http_status(:forbidden)
      expect(repository.reload.github_full_name).to eq("acme/billing-service")

      get edit_repository_path(repository)
      expect(response).to have_http_status(:forbidden)
    end

    # @intent: {"entity": "RepositoryMembership", "action": "refuse removal", "behavior": "DELETE /repositories/:id answers 403 and destroys no Repository row for a view-only member", "layer": "request"}
    it "cannot remove the repository" do
      expect {
        delete repository_path(repository)
      }.not_to change(Repository, :count)

      expect(response).to have_http_status(:forbidden)
    end

    # Slice 1 listed only owned repositories, so a shared one was reachable by URL and on no page
    # the member could get to. Slice 2a is where that changes — this is slice 1's own tripwire,
    # inverted.
    # @intent: {"entity": "RepositoryMembership", "action": "list shared repository", "behavior": "the member's index renders 200 listing acme/billing-service with a link to its repository path", "layer": "request"}
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
    # @intent: {"entity": "RepositoryMembership", "action": "badge the owner login", "behavior": "the shared card badge names the owner's login octocat rather than the slug's org segment acme", "layer": "request"}
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
    # @intent: {"entity": "RepositoryMembership", "action": "name owner in overview", "behavior": "the Overview panel renders an Owner term with octocat as its adjacent value and never acme in that row", "layer": "request"}
    it "sees the owner named in the Overview panel, not the slug's org segment" do
      get repository_path(repository)

      expect(response.body).to match(%r{<dt[^>]*>\s*Owner\s*</dt>\s*<dd[^>]*>\s*octocat\s*</dd>}m)
      expect(response.body).not_to match(%r{<dt[^>]*>\s*Owner\s*</dt>\s*<dd[^>]*>\s*acme\s*</dd>}m)
    end

    # Decision (b). repositories#show gates every scrap of key metadata — names, hints, last-used —
    # behind `keys.manage`, so the card must not hand this member a key count the page it links to
    # would refuse them. The suite size is not credential information and stays.
    # @intent: {"entity": "RepositoryMembership", "action": "hide key count", "behavior": "with one API key and a 1,234-test run on the card a view-only member sees 1,234 tests and no key count", "layer": "request"}
    it "sees no key count on the shared card, but still sees the suite size" do
      repository.api_keys.create!(name: "CI")
      create_test_run(repository: repository, total_specs_count: 1234)

      get repositories_path

      expect(response.body).not_to include("1 key")
      expect(response.body).to include("1,234 tests")
    end

    # Decision (d). "Every repository you have registered" stopped being true the moment shared
    # repositories appeared in this list — the member registered none of them.
    # @intent: {"entity": "RepositoryMembership", "action": "admit shared subtitle", "behavior": "the index subtitle says shared with you rather than every repository you have registered", "layer": "request"}
    it "sees a subtitle that admits the list is not all their own registrations" do
      get repositories_path

      expect(response.body).to include("shared with you")
      expect(response.body).not_to include("Every repository you have registered")
    end
  end

  describe "a member with 'keys.manage'" do
    before { sign_in_as_member(%w[view keys.manage]) }

    # @intent: {"entity": "RepositoryMembership", "action": "mint and revoke key", "behavior": "POST adds one ApiKey row and the redirect reveals an sgk_ token, then DELETE drops the count back by one", "layer": "request"}
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
    # @intent: {"entity": "RepositoryMembership", "action": "show key count", "behavior": "a member holding keys.manage sees the 1 key count on the shared card, the positive control for the view-only suppression", "layer": "request"}
    it "sees the key count on the shared card" do
      repository.api_keys.create!(name: "CI")

      get repositories_path

      expect(response.body).to include("1 key")
    end
  end

  describe "a member with 'repo.delete'" do
    before { sign_in_as_member(%w[view repo.delete]) }

    # @intent: {"entity": "RepositoryMembership", "action": "remove shared repository", "behavior": "DELETE /repositories/:id destroys the repository, dropping Repository.count by one, and redirects to the index", "layer": "request"}
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

    # @intent: {"entity": "RepositoryMembership", "action": "open without view grant", "behavior": "a member granted keys.manage with no view still gets 200 on the repository page", "layer": "request"}
    it "can still open the repository" do
      get repository_path(repository)

      expect(response).to have_http_status(:ok)
    end
  end

  # The Overview panel's "Your access" row — what the reader HOLDS, rather than a fourth surface
  # naming the owner as the person to ask for more.
  #
  # `RepositoriesController#show` authorizes at `:view`, which is what makes this the surface that
  # reaches everybody: the members table was previously the only place SpecGuard ever displayed an
  # access set to a human, and `MembershipsController#index` authorizes at `:members_manage`. So a
  # colleague who administers other people could find their own row incidentally, in a table built
  # for administering somebody else, and a `view` colleague or a key-minter had nowhere at all.
  #
  # Every example below signs in as a member and none of them holds `members.manage`, which is the
  # point rather than an accident: gating this row on that permission would reproduce the defect.
  describe "what repositories#show tells a member about their own access" do
    # The row's value, read off the DefList by its term. Anchored on the term/value adjacency for
    # the same reason the "Owner" example above is, and with the same standing instruction: if this
    # regex fails after a change to `DefListComponent` while the panel still names the access
    # correctly, re-anchor it on whatever the component now renders. A bare substring match is not
    # the fallback — the permission strings are short tokens and would match half the page.
    def access_row
      response.body[%r{<dt[^>]*>\s*Your access\s*</dt>\s*<dd[^>]*>\s*(.*?)\s*</dd>}m, 1]
    end

    # The sentence underneath, read as TEXT so its apostrophes and dashes arrive unescaped and the
    # assertions below can be written as the reader sees them. Found by its closing clause rather
    # than by position, so it cannot silently start reading one of the Overview panel's several
    # other muted paragraphs if the panel is reordered.
    def access_description
      css_select("p").map { |node| node.text.squish }
                     .find { |text| text.include?("That is everything you hold here") }
    end

    # The closing clause, quoted once. It is the whole reason the row exists: this page renders no
    # control its viewer does not hold, so without a sentence naming the set as complete, ABSENCE is
    # the only signal — and absence reads identically for "never granted", "granted but broken" and
    # "SpecGuard does not do this".
    let(:closing) do
      "That is everything you hold here — a control this page does not show you is one you have " \
        "not been granted, not one that is broken or missing."
    end

    # `eq` and not `include`, deliberately: "and nothing beyond it" is half of what this row has to
    # say, and only equality can prove a second capability was not also named.
    # @intent: {"entity": "RepositoryMembership", "action": "state view-only access", "behavior": "the Your access row reads view and its sentence reads Open the repository followed by the closing clause that a control not shown is one not granted", "layer": "request"}
    it "tells a 'view' member they may open it, and that this is the whole of it" do
      sign_in_as_member(%w[view])

      get repository_path(repository)

      expect(access_row).to eq("view")
      expect(access_description).to eq("Open the repository. #{closing}")
    end

    # @intent: {"entity": "RepositoryMembership", "action": "state both permissions", "behavior": "the row reads view, keys.manage and the sentence spells open the repository plus see, mint and revoke this repository's API keys before the same closing clause", "layer": "request"}
    it "names both of a member's permissions, in the words the grant side uses" do
      sign_in_as_member(%w[view keys.manage])

      get repository_path(repository)

      expect(access_row).to eq("view, keys.manage")
      expect(access_description).to eq(
        "Open the repository. See, mint and revoke this repository's API keys. #{closing}"
      )
    end

    # The example that decides the derivation. This row stores no "view" at all, yet the member can
    # open the page — `RepositoryPolicy#can?` grants view on the membership itself — so a row built
    # from `membership.permissions` would tell them they may manage keys on a repository they are
    # not allowed to open, which is both incoherent and false. Reading through
    # `grantable_permissions` (derived from `can?`) is what makes the answer the effective one.
    # @intent: {"entity": "RepositoryMembership", "action": "derive effective access", "behavior": "a membership storing only keys.manage still renders the row as view, keys.manage, the set read through the effective grantable permissions", "layer": "request"}
    it "tells a member whose row omits 'view' that they may still open the repository" do
      sign_in_as_member(%w[keys.manage])

      get repository_path(repository)

      expect(access_row).to eq("view, keys.manage")
      expect(access_description).to start_with("Open the repository.")
    end

    # The owner's page is unchanged, and that is a requirement rather than an omission: they hold
    # every capability implicitly and the "Owner" row already names them, so a row here would be a
    # second truth about the same person that could contradict the first.
    # @intent: {"entity": "RepositoryMembership", "action": "omit owner access row", "behavior": "the owner's page renders no Your access row or description while the Owner row still names octocat", "layer": "request"}
    it "says nothing about access on the owner's own page" do
      repository
      sign_in_via_github

      get repository_path(repository)

      expect(response.body).not_to include("Your access")
      expect(access_description).to be_nil
      # The positive control: without it this passes just as well if the whole panel stops
      # rendering, which would take the "Owner" row with it and prove the opposite of the point.
      expect(response.body).to match(%r{<dt[^>]*>\s*Owner\s*</dt>\s*<dd[^>]*>\s*octocat\s*</dd>}m)
    end

    # The row asks `can?` four times, and every one of them has to be served by the membership row
    # `current_repository(:view)` already loaded to authorize the request — `repository_policy` is
    # memoized per repository and memoizes the row inside it.
    #
    # Reduces to reads of `repository_memberships`, not to a total: that is exactly the read a
    # re-derivation would add (a `find_by` in the template, or reaching past the policy for the
    # row), and a total would move for reasons this example is not about. The delta example further
    # down covers the total from the other direction.
    #
    # Counted through its own subscriber rather than `executed_sql`, and the difference is the whole
    # point. `executed_sql` drops `payload[:cached]` because a cached repeat is not work the page
    # chose to do — true of the queries it is used for, and false here: the likeliest wrong
    # implementation is a second `find_by` for the SAME row, which ActiveRecord's per-request query
    # cache serves byte-identically and therefore invisibly. Counting cached repeats is what makes
    # this example able to fail at all.
    def membership_reads
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        next if payload[:name].in?(["SCHEMA", "TRANSACTION"])

        queries << payload[:sql] if payload[:sql].to_s.match?(/from "repository_memberships"/i)
      end
      yield
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # @intent: {"entity": "RepositoryMembership", "action": "reuse authorizing membership read", "behavior": "the page issues exactly one repository_memberships read with cached repeats counted, so the four can? asks are served by the row that authorized the request", "layer": "request"}
    it "costs no membership read beyond the one that authorized the request" do
      sign_in_as_member(%w[view])

      get repository_path(repository)
      reads = membership_reads { get repository_path(repository) }

      expect(access_row).to eq("view")
      expect(reads.size).to eq(1)
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
    # @intent: {"entity": "RepositoryMembership", "action": "render all controls", "behavior": "the owner's page renders all six control markers: rename, remove, new key, revoke, key inventory and members", "layer": "request"}
    it "renders all of them for the owner" do
      repository
      sign_in_via_github

      get repository_path(repository)

      expect(response).to have_http_status(:ok)
      expect(rendered_controls.values).to all(be(true))
    end

    # @intent: {"entity": "RepositoryMembership", "action": "suppress all controls", "behavior": "a view-only member's page renders none of the six control markers while still showing acme/billing-service", "layer": "request"}
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
    # @intent: {"entity": "RepositoryMembership", "action": "render key controls only", "behavior": "a keys.manage member gets the new-key, revoke and key-inventory markers and none of rename, remove or members", "layer": "request"}
    it "renders the key controls, and only those, for a member with 'keys.manage'" do
      sign_in_as_member(%w[view keys.manage])

      get repository_path(repository)

      expect(rendered_controls).to eq(
        rename: false, remove: false, new_key: true, revoke: true, key_inventory: true, members: false
      )
    end

    # @intent: {"entity": "RepositoryMembership", "action": "render remove only", "behavior": "a repo.delete member gets only the remove control, with rename, new key, revoke, key inventory and members all absent", "layer": "request"}
    it "renders remove, and only that, for a member with 'repo.delete'" do
      sign_in_as_member(%w[view repo.delete])

      get repository_path(repository)

      expect(rendered_controls).to eq(
        rename: false, remove: true, new_key: false, revoke: false, key_inventory: false, members: false
      )
    end
  end

  # The matrix above pins *whether* Remove renders. This pins what it says once it has — the other
  # half of the same problem, and the one that stayed unaddressed longest. `#destroy` gates at
  # `:repo_delete`, not `:owner`, so the presser of this button is not necessarily its owner, yet
  # both sentences they read (the confirm dialog, then the flash) were written as if they were.
  #
  # Every example asserts the whole sentence with `eq`, never a substring. The owner's half of this
  # change is that *nothing* changed for them, and an `include` cannot prove a dialog did not grow a
  # second sentence — only equality can.
  describe "what Remove says about whose repository it is" do
    # `repository`'s owner is 'octocat' and `sign_in_as_member` signs in 'hubot', so an assertion
    # that the copy names "octocat" proves it named the *owner* and not merely the reader.
    let(:owner_dialog) { "Remove acme/billing-service and all of its data?" }

    # The dialog lives in an HTML attribute, so its apostrophe arrives as `&#39;`. Unescaping once
    # here buys whole-sentence equality below instead of assertions hand-written in escaped form.
    #
    # Selected by prefix rather than by position: the owner's page renders a second confirm dialog
    # further down (Revoke, on each API key row), and matching the first attribute in the document
    # would silently start reading that one if the header were ever reordered.
    def remove_dialog
      response.body.scan(/data-turbo-confirm="([^"]*)"/).flatten
              .map { |value| CGI.unescapeHTML(value) }
              .find { |value| value.start_with?("Remove ") }
    end

    describe "the owner" do
      before do
        repository
        sign_in_via_github
      end

      # @intent: {"entity": "RepositoryMembership", "action": "keep owner dialog", "behavior": "the owner's confirm dialog still reads Remove acme/billing-service and all of its data? byte for byte", "layer": "request"}
      it "reads the dialog it always read" do
        get repository_path(repository)

        expect(remove_dialog).to eq(owner_dialog)
      end

      # @intent: {"entity": "RepositoryMembership", "action": "keep owner flash", "behavior": "after DELETE the owner's flash still reads Removed acme/billing-service.", "layer": "request"}
      it "reads the flash it always read" do
        delete repository_path(repository)

        expect(flash[:notice]).to eq("Removed acme/billing-service.")
      end
    end

    describe "a member holding 'repo.delete'" do
      before { sign_in_as_member(%w[view repo.delete]) }

      # The first sentence is byte-identical to the owner's on purpose — `rendered_controls` above
      # detects this control by the substring "and all of its data?", so the member variant appends
      # rather than rewords.
      # @intent: {"entity": "RepositoryMembership", "action": "warn member before confirm", "behavior": "the member's dialog appends It belongs to octocat, naming the destruction of the owner's API keys, run history and every other member's access, onto the unchanged first sentence", "layer": "request"}
      it "is told whose repository it is, and what goes with it, before confirming" do
        get repository_path(repository)

        expect(remove_dialog).to eq(
          "#{owner_dialog} It belongs to octocat — this destroys their repository along with " \
          "its API keys, its entire run history and every other member's access."
        )
      end

      # @intent: {"entity": "RepositoryMembership", "action": "tell member after removal", "behavior": "the member's post-DELETE flash appends that it was octocat's repository and that its API keys, run history and member access went with it", "layer": "request"}
      it "is told whose repository it was afterwards" do
        delete repository_path(repository)

        expect(flash[:notice]).to eq(
          "Removed acme/billing-service. It was octocat's repository — its API keys, its run " \
          "history and every other member's access went with it."
        )
      end

      # The owner is the SpecGuard account that registered the repository, which the slug does not
      # name: `github_full_name`'s org segment is a *GitHub* org and nothing constrains the two to
      # match (see Repository#user; SPGD-145 retired `owner_login` for this reason). A repository
      # owned by 'octocat' but registered under an unrelated slug is the case that separates
      # reading the owner off the association from reading it off the string.
      # @intent: {"entity": "RepositoryMembership", "action": "name owning account", "behavior": "under an unrelated some-other-org slug the dialog and flash still name octocat and never the org segment", "layer": "request"}
      it "names the owning account rather than the slug's org segment" do
        repository.update!(github_full_name: "some-other-org/billing-service")

        get repository_path(repository)
        expect(remove_dialog).to include("It belongs to octocat")
        expect(remove_dialog).not_to include("some-other-org —")

        delete repository_path(repository)
        expect(flash[:notice]).to include("It was octocat's repository")
      end
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

    # @intent: {"entity": "RepositoryMembership", "action": "gate ex-member marker", "behavior": "the owner sees the no-longer-has-access marker on the departed minter's key, while a keys.manage member still sees the Their CI row and the departed-dev name without the marker", "layer": "request"}
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
    # every query either of them issues is in scope — which is `count_queries` from
    # spec/support/query_capture.rb, unreduced.

    # @intent: {"entity": "RepositoryMembership", "action": "charge no hidden read", "behavior": "a members.manage viewer who cannot reach the keys panel issues the same total query count as the view-only baseline and still sees no Their CI row", "layer": "request"}
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
    # Deliberately counts only reads of `users`, not every SELECT, so this example fails for the
    # one reason it is about — the owner name — and not for a cost some other card question grew.
    # It used to say the page had per-card queries it could not help but include in a total; that
    # is no longer true. The intent count it named is gone (the card reads suite size off the
    # preloaded newest run), and the key count that outlived it is grouped for the whole page too,
    # under its own guard in the block below. Reducing per table is now a matter of keeping each
    # example's failure legible, not of stepping around costs nobody was watching.
    def user_table_queries(&) = executed_sql(&).grep(/from "users"/i).size

    # @intent: {"entity": "RepositoryMembership", "action": "batch owner reads", "behavior": "three shared cards owned by three different accounts render all their Shared badges at the one-card users-table read count", "layer": "request"}
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

  # The key count is the index's other per-card question, and the one the guard above deliberately
  # cannot see. It gets its own, on the same footing: one query for the page, however long the list.
  describe "what counting API keys costs the index per card" do
    # Reduces on reads of `api_keys` for the same reason the block above reduces on `users` — each
    # example watches the one table its own subject can move. A per-card `.size` on an unpreloaded
    # association issues the COUNTs itself, so removing it removes the events `executed_sql` sees;
    # there is nothing here that a total would catch and this does not.
    def api_key_queries(&) = executed_sql(&).grep(/from "api_keys"/i).size

    # @intent: {"entity": "RepositoryMembership", "action": "batch key counts", "behavior": "three cards carrying one, two and three keys each render their own count at the one-card api_keys read count", "layer": "request"}
    it "reads the api_keys table no more often for three cards than for one" do
      member = sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
      create_membership(repository: repository, user: member, permissions: %w[view keys.manage])
      repository.api_keys.create!(name: "CI")

      get repositories_path
      baseline = api_key_queries { get repositories_path }

      # Each extra card gets a *different* number of keys, so the control below proves every card
      # was handed its own figure. A grouped count that mapped rows to the wrong repository would
      # still issue exactly one query and pass an assertion that only counted queries.
      %w[2002 3003].each_with_index do |uid, index|
        other = create_repository(user: create_user(github_uid: uid, github_handle: "owner-#{index}"),
                                  github_full_name: "org#{index}/service")
        (index + 2).times { |n| other.api_keys.create!(name: "CI-#{n}") }
        create_membership(repository: other, user: member, permissions: %w[view keys.manage])
      end

      get repositories_path

      # The positive control: without it this would keep passing if the badge stopped rendering.
      expect(response.body).to include("1 key").and include("2 keys").and include("3 keys")
      expect(api_key_queries { get repositories_path }).to eq(baseline)
    end

    # The one way grouping could change what a card *says*: a grouped count has no row at all for
    # a repository with no keys, where the association call it replaced answered 0. "No keys yet"
    # is a real state the badge has always spelled out, and it must survive the reader change.
    # @intent: {"entity": "RepositoryMembership", "action": "render zero key count", "behavior": "a shared repository with no keys renders 0 keys on its card, the state a grouped count has no row for", "layer": "request"}
    it "still reads '0 keys' on a card whose repository has none" do
      member = sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
      create_membership(repository: repository, user: member, permissions: %w[view keys.manage])

      get repositories_path

      expect(repository.api_keys).to be_empty
      expect(response.body).to include("0 keys")
    end
  end

  describe "a signed-in user with no membership" do
    before do
      repository
      sign_in_via_github(uid: "8888")
    end

    # Existence stays hidden — the same shape as before sharing existed, when `current_repository`
    # scoped its `.find` to the signed-in user's own repositories.
    # @intent: {"entity": "RepositoryMembership", "action": "hide repository from stranger", "behavior": "a signed-in non-member gets 404 on show, edit, patch, key mint and destroy, with no ApiKey or Repository row changed", "layer": "request"}
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
    # @intent: {"entity": "RepositoryMembership", "action": "empty index for stranger", "behavior": "the non-member's index answers 200 with No repositories yet and never mentions acme/billing-service", "layer": "request"}
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

    # @intent: {"entity": "RepositoryMembership", "action": "operate without membership row", "behavior": "the owner opens the page, renames to acme/renamed, mints a key and destroys the repository while holding zero RepositoryMembership rows", "layer": "request"}
    it "still does everything with no membership row of their own" do
      # The rename target has to be in the installation, because renaming re-verifies the new name
      # against it exactly as registering would — see `InstallationRepositories`.
      stub_github(repos: [github_repo("acme/billing-service"), github_repo("acme/renamed")])
      expect(RepositoryMembership.where(user: owner)).to be_empty

      get repository_path(repository)
      expect(response).to have_http_status(:ok)

      patch repository_path(repository), params: { repository: { github_full_name: "acme/renamed" } }
      expect(repository.reload.github_full_name).to eq("acme/renamed")

      expect { post repository_api_keys_path(repository) }.to change(ApiKey, :count).by(1)
      expect { delete repository_path(repository) }.to change(Repository, :count).by(-1)
    end

    # @intent: {"entity": "RepositoryMembership", "action": "ignore foreign membership", "behavior": "another user's full-permission membership leaves the owner's GET at 200", "layer": "request"}
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
    # @intent: {"entity": "RepositoryMembership", "action": "dedupe owned listing", "behavior": "with two membership rows on an owned repository the index links it exactly once rather than once per member", "layer": "request"}
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
    # @intent: {"entity": "RepositoryMembership", "action": "omit owned badge", "behavior": "the owner's own card carries no Shared badge while still listing acme/billing-service", "layer": "request"}
    it "renders no owner badge on a repository it owns" do
      get repositories_path

      expect(response.body).to include("acme/billing-service")
      expect(response.body).not_to include("Shared ·")
    end

    # The other half of decision (b): the owner holds every capability, so their card is unchanged.
    # @intent: {"entity": "RepositoryMembership", "action": "show owner both counts", "behavior": "the owner's card shows both 1 key and 1,234 tests, unchanged by the gating that hides the count from viewers", "layer": "request"}
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
    # @intent: {"entity": "RepositoryMembership", "action": "sort union globally", "behavior": "the shared aa/shared card sorts ahead of the viewer's own zz/owned, so the union renders ordered rather than owned-then-shared", "layer": "request"}
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
