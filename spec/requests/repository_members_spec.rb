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
      membership = create_membership(repository: repository, user: colleague)

      get repository_members_path(repository)

      expect(response.body).to include("hubot")
      # The owner's own handle is in the topbar — they are signed in — so this has to be scoped to
      # the table. Asserted as the set of membership ids the page links to rather than as a count of
      # controls: each row now carries Edit *and* Revoke, so counting matches would need a constant
      # bumped every time a control is added to the cell, and would stay green if the second link
      # pointed at the wrong row. The set says the stronger thing — exactly one member row, and it
      # is the colleague's.
      linked_ids = response.body.scan(%r{/repositories/#{repository.id}/members/(\d+)}).flatten.uniq
      expect(linked_ids).to eq([membership.id.to_s])
      expect(response.body).not_to include("Revoke octocat")
    end

    # A blank table says "loading failed" as readily as "nobody has access"; and the empty state is
    # where the owner picks up the one control that changes it. The inversion of slice 2b's example,
    # which asserted the page named add-by-handle as unavailable.
    it "sees an empty state offering the add-by-handle form, not a blank table" do
      get repository_members_path(repository)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No one else has access")
      expect(response.body).to include(new_repository_member_path(repository))
      # "Only X can reach this repository" is a factual claim about SpecGuard access, so X must be
      # the owning account. `acme` is the org segment of the slug and names no SpecGuard account —
      # the fixture keeps the two different (owner @octocat, slug acme/billing-service) so this
      # assertion cannot pass on a coincidence of naming.
      expect(response.body).to include("Only octocat can reach this repository")
      expect(response.body).not_to include("Only acme can reach")
      expect(response.body).not_to include("not available yet")
      # The console is no longer the way in, so the page must not still say it is.
      expect(response.body).not_to include("created from the console")
    end

    it "can revoke a member's access" do
      membership = create_membership(repository: repository, user: colleague)

      expect {
        delete repository_member_path(repository, membership)
      }.to change(RepositoryMembership, :count).by(-1)

      expect(response).to redirect_to(repository_members_path(repository))
    end
  end

  # Slice 2c: the grant form, and the first production call site `User.resolve_by_handle` has ever
  # had. `new`/`create` gated one step tighter than the page, at `:owner`, until the checkbox grid
  # gave `grantable_permissions` a call site; they gate at the same `members.manage` that opens the
  # page now, bounded by what the grantor themselves holds — see MembershipsController, and "can
  # add a member, and is offered the control that does it" below, which grants as an actor who is
  # not the owner. The examples in THIS block sign in as the owner, for whom the two gates have
  # always been the same, so nothing here distinguishes them.
  describe "adding a member by GitHub handle" do
    # Exactly what the form submits. The leading "" is the hidden field every checkbox grid needs so
    # that "nothing ticked" arrives as an empty set rather than as no parameter at all — passing the
    # tidy array a hand-written client would send is how a spec stops exercising the real form.
    def add_member(handle, permissions = [])
      post repository_members_path(repository),
           params: { membership_grant: { handle: handle, permissions: [""] + permissions } }
    end

    before do
      repository
      sign_in_via_github
    end

    # DoD bullet 1, end to end: the owner names a colleague, and the colleague sees the repository.
    # The second half is slice 2a's path, asserted here because a grant that stores a row nobody
    # gains access from closes nothing.
    it "grants the colleague access, who then sees the repository in their own index" do
      colleague

      expect {
        add_member("hubot", %w[view keys.manage])
      }.to change(RepositoryMembership, :count).by(1)

      expect(response).to redirect_to(repository_members_path(repository))
      expect(RepositoryMembership.last.user).to eq(colleague)

      sign_in_via_github(uid: "9999", info: { nickname: "hubot" })

      get repositories_path
      expect(response.body).to include("acme/billing-service")
    end

    # `permissions` is a `text[]`, and the trap is that mis-permitting it fails SILENTLY: a scalar
    # `params.expect(... :permissions)` drops the array and persists `[]`, which is still a working
    # membership. So this asserts the stored array itself — "a row was created" stays green either
    # way, and the owner would only ever notice as "the checkboxes do nothing".
    it "stores exactly the permissions that were ticked" do
      colleague

      add_member("hubot", %w[view keys.manage])

      expect(RepositoryMembership.last.permissions).to eq(%w[view keys.manage])
    end

    # The other half of the same pair, and the reason the empty set must not be "helpfully" filled
    # in: `view` is implied by the membership row itself (RepositoryPolicy#can?), so a member with
    # nothing ticked can still open the repository. Force-adding "view" here would make this
    # indistinguishable from the ticked case and hide the trap above.
    it "stores an empty set when nothing is ticked, and that member can still open the repository" do
      colleague

      expect { add_member("hubot") }.to change(RepositoryMembership, :count).by(1)
      expect(RepositoryMembership.last.permissions).to eq([])

      sign_in_via_github(uid: "9999", info: { nickname: "hubot" })

      get repository_path(repository)
      expect(response).to have_http_status(:ok)
    end

    # `RepositoryMembership#grantor_holds_every_granted_permission` bounds a grant by what the
    # grantor holds, and fails OPEN on a nil grantor — so a `create` that forgot to name one would
    # write the only rows in the product that bound does not constrain. The model states this is the
    # writer's job; this is the assertion that the writer did it.
    it "records the signed-in owner as the grantor" do
      colleague

      add_member("hubot", %w[view])

      expect(RepositoryMembership.last.granted_by_user).to eq(owner)
    end

    # And it must come from the *session*, never the request body. The validation trusts the grantor
    # it is handed, so a form that permitted this would let a submitted id name someone with wider
    # rights and compute the bound against theirs — a save that reports success while the escalation
    # the validation exists to close is reopened.
    it "ignores a grantor submitted through the form" do
      colleague
      impostor = create_user(github_uid: "4004", github_handle: "impostor")

      post repository_members_path(repository),
           params: { membership_grant: { handle: "hubot", permissions: [""],
                                         granted_by_user_id: impostor.id } }

      expect(RepositoryMembership.last.granted_by_user).to eq(owner)
    end

    # Two rows legitimately share a recycled handle (see sessions_spec). Picking one would silently
    # grant a private repository to a stranger, which is the whole reason `resolve_by_handle` returns
    # a four-way answer instead of a User.
    it "refuses an ambiguous handle without creating a row, and names how many accounts share it" do
      create_user(github_uid: "9999", github_handle: "hubot")
      create_user(github_uid: "8888", github_handle: "hubot")

      expect { add_member("hubot", %w[view]) }.not_to change(RepositoryMembership, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("2 accounts share the handle hubot")
    end

    # The anti-collapse control, and the reason it is a matrix rather than five separate examples:
    # each of those would still pass if the *other* four sentences were rendered alongside its own.
    # Distinctness is the property `User::Resolution` exists to protect — "nobody holds that handle"
    # and "that is not a handle" send the owner to fix entirely different things — so it is asserted
    # directly. The last two are RepositoryMembership's own messages, surfaced rather than restated.
    it "answers each refusal with its own sentence and never another's" do
      create_user(github_uid: "7777", github_handle: "twin")
      create_user(github_uid: "6666", github_handle: "twin")
      create_membership(repository: repository, user: colleague)

      refusals = {
        "ghost" => "Nobody has signed into SpecGuard as ghost yet",
        "The Octocat" => "That is not a GitHub handle",
        "twin" => "2 accounts share the handle twin",
        "octocat" => "User already owns this repository",
        "hubot" => "User already has a membership on this repository"
      }

      refusals.each do |handle, own_message|
        expect { add_member(handle, %w[view]) }.not_to change(RepositoryMembership, :count)

        expect(response).to have_http_status(:unprocessable_content), "#{handle} was not refused"
        expect(response.body).to include(own_message)
        (refusals.values - [own_message]).each do |other_message|
          expect(response.body).not_to include(other_message)
        end
      end
    end

    # A rejected submission re-renders, so the owner does not retype a handle and re-tick a grid to
    # fix one word. A redirect would lose both.
    it "re-renders the form with what was typed and ticked" do
      add_member("ghost", %w[keys.manage])

      expect(response.body).to include(%(value="ghost"))
      expect(response.body).to match(/value="keys\.manage"[^>]*checked/)
      # The negative half: a grid that rendered every box checked would pass the line above.
      expect(response.body).not_to match(/value="repo\.delete"[^>]*checked/)
    end

    it "offers the form from the members page" do
      get repository_members_path(repository)
      expect(response.body).to include(new_repository_member_path(repository))

      get new_repository_member_path(repository)
      expect(response).to have_http_status(:ok)
      # Every permission is offered: under an owner, `grantable_permissions` is the full set.
      RepositoryMembership::PERMISSIONS.each { |permission| expect(response.body).to include(permission) }
    end
  end

  # Slice 2c gated `new`/`create` at `:owner` and this block pinned that. Slice 2f widens it to the
  # `:members_manage` that opens the page, which is what the roadmap's own definition of the
  # permission says it buys ("add/remove collaborators, edit permissions") — all three clauses, not
  # the middle one alone.
  #
  # What made the tighter gate defensible was that `grantable_permissions` had no call site, so
  # nothing bounded what a non-owner's invite could contain. Every grid on this controller renders
  # from it now, so the escalation the gate was standing in for is closed by the grid and the
  # model's `grantor_holds_every_granted_permission` together — which is the thing actually asserted
  # below, rather than "a non-owner is refused".
  describe "who may grant access" do
    def attempt_grant(permissions = %w[view])
      post repository_members_path(repository),
           params: { membership_grant: { handle: "dependabot", permissions: [""] + permissions } }
    end

    let(:third_party) { create_user(github_uid: "8888", github_handle: "dependabot") }

    before { third_party }

    context "a member holding 'members.manage'" do
      before do
        create_membership(repository: repository, user: colleague, permissions: %w[view members.manage])
        sign_in_via_github(uid: "9999")
      end

      it "can add a member, and is offered the control that does it" do
        get repository_members_path(repository)
        expect(response.body).to include(new_repository_member_path(repository))

        get new_repository_member_path(repository)
        expect(response).to have_http_status(:ok)

        expect { attempt_grant }.to change(RepositoryMembership, :count).by(1)
        expect(response).to redirect_to(repository_members_path(repository))
      end

      # The bound that replaced the `:owner` gate, asserted as behaviour rather than assumed. The
      # grid does not offer `repo.delete` to this actor, and the model refuses it even when the
      # request is written by hand — the two halves matter separately, because only the second
      # survives a client that ignores the form.
      it "is offered only what they hold, and is refused anything more even by hand" do
        get new_repository_member_path(repository)

        expect(response.body).to include("members.manage")
        expect(response.body).not_to include("repo.delete")
        expect(response.body).not_to include("keys.manage")

        expect { attempt_grant(%w[view repo.delete]) }.not_to change(RepositoryMembership, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("the grantor does not hold: repo.delete")
      end

      # The grantor stamp on the add door, from this actor's session rather than the owner's — the
      # bound above is only as good as the identity it is computed against.
      it "records itself as the grantor, not the owner" do
        attempt_grant

        expect(RepositoryMembership.find_by!(user: third_party).granted_by_user).to eq(colleague)
      end
    end

    context "a member with only 'view'" do
      before do
        create_membership(repository: repository, user: colleague, permissions: %w[view])
        sign_in_via_github(uid: "9999")
      end

      # `grantable_permissions` returns `["view"]` for this member — non-empty, and deliberately not
      # read as permission to invite anyone. RepositoryPolicy says so itself: "Reading a non-empty
      # result here as permission to manage members would let a view-only member start inviting
      # people." This is the example that fails if the controller ever asks the grid instead of
      # asking `can?(:members_manage)`.
      it "gets 403 on the form and the grant" do
        get new_repository_member_path(repository)
        expect(response).to have_http_status(:forbidden)

        expect { attempt_grant }.not_to change(RepositoryMembership, :count)
        expect(response).to have_http_status(:forbidden)
      end
    end

    # 404 rather than 403: the repository's existence stays hidden from a non-member here too.
    context "a signed-in user with no membership" do
      before { sign_in_via_github(uid: "7777") }

      it "gets 404 on the form and the grant" do
        get new_repository_member_path(repository)
        expect(response).to have_http_status(:not_found)

        expect { attempt_grant }.not_to change(RepositoryMembership, :count)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # Slice 2f: editing a member's permissions in place. Closes the half of DoD bullet 4 that Remove
  # shipped without — "the owner can EDIT or remove a colleague's access".
  #
  # Before this, narrowing a colleague had exactly one path: Revoke, then re-add. That path fires a
  # consequence dialog about API keys that will keep authenticating (for an operation that is not a
  # removal), and destroys the row, so the "Since" column resets and a colleague who merely lost a
  # permission reports as newly added. Same argument RepositoriesController#update makes for rename
  # one level up: "the alternative (Remove + re-register) destroys every key and all telemetry."
  describe "editing a member's permissions" do
    # Exactly what the form submits. The leading "" is the hidden field that makes "nothing ticked"
    # arrive as an empty set rather than as no parameter at all — passing the tidy array a
    # hand-written client would send is how a spec stops exercising the real form, and on THIS form
    # the empty case is the whole point.
    def edit_member(membership, permissions = [])
      patch repository_member_path(repository, membership),
            params: { repository_membership: { permissions: [""] + permissions } }
    end

    let!(:membership) do
      create_membership(repository: repository, user: colleague, permissions: %w[view keys.manage])
    end

    describe "the owner" do
      before { sign_in_via_github }

      # Criterion 1, and the reason the whole slice exists. Asserted on the SAME row — the id and
      # created_at are what separate "edited" from "revoked and re-added", and a spec that only
      # checked the stored array would stay green if the implementation destroyed and recreated.
      it "narrows a member in place, keeping the row and the date they were added" do
        original_created_at = membership.created_at

        expect { edit_member(membership, %w[view]) }.not_to change(RepositoryMembership, :count)

        expect(response).to redirect_to(repository_members_path(repository))
        expect(membership.reload.permissions).to eq(%w[view])
        expect(membership.created_at).to eq(original_created_at)
      end

      # Criterion 2 — the narrowing case a naive form breaks. Browsers omit unchecked boxes
      # entirely, so with no hidden blank the `permissions` key vanishes and `params.expect` raises
      # ParameterMissing → 400. This is the example that fails if that hidden field is dropped.
      #
      # The second half is why `[]` must not be "helpfully" filled in with "view": membership itself
      # grants access (RepositoryPolicy#can?), so the colleague is narrowed, not locked out. Asserted
      # from their own session, because that is the claim the flash makes to the owner.
      it "stores an empty set when every box is unchecked, and that member can still open the repository" do
        expect { edit_member(membership) }.not_to change(RepositoryMembership, :count)

        expect(response).to redirect_to(repository_members_path(repository))
        expect(membership.reload.permissions).to eq([])

        sign_in_via_github(uid: "9999", info: { nickname: "hubot" })

        get repository_path(repository)
        expect(response).to have_http_status(:ok)
      end

      it "can widen a member too, not only narrow them" do
        edit_member(membership, %w[view keys.manage members.manage repo.delete])

        expect(membership.reload.permissions).to eq(%w[view keys.manage members.manage repo.delete])
      end

      # Criterion 3's first half. `create_membership` names no grantor — as the console and every
      # spec builder do — so this row arrives with a nil one, which is the state
      # `grantor_holds_every_granted_permission` fails OPEN on. The stamp is what converts it to a
      # bounded row.
      it "stamps the editor as the grantor, including on a row that had none" do
        expect(membership.granted_by_user).to be_nil

        edit_member(membership, %w[view])

        expect(membership.reload.granted_by_user).to eq(owner)
      end

      # Criterion 5. `permissions` is the only attribute this form may change. Each of these is a
      # distinct attack: `user_id` would move a colleague's access onto somebody else, `repository_id`
      # would move the row out from under the authorization that admitted the request, and
      # `granted_by_user_id` would name a wider-rights grantor so the bound is computed against
      # theirs. All three are submitted in ONE request, so a filter that catches two of them and
      # misses the third still fails here.
      it "changes nothing but the permissions, whatever else is in the body" do
        impostor = create_user(github_uid: "4004", github_handle: "impostor")
        other_repository = create_repository(user: owner, github_full_name: "acme/payments-service")

        patch repository_member_path(repository, membership),
              params: { repository_membership: { permissions: ["", "view"],
                                                 user_id: impostor.id,
                                                 repository_id: other_repository.id,
                                                 granted_by_user_id: impostor.id } }

        membership.reload
        expect(membership.permissions).to eq(%w[view])
        expect(membership.user).to eq(colleague)
        expect(membership.repository).to eq(repository)
        expect(membership.granted_by_user).to eq(owner)
      end

      # Criterion 7's positive control: the owner's `grantable_permissions` is the full set, so the
      # grid offers everything. Without this, restricting the grid to nothing at all would pass the
      # negative assertions further down.
      it "is offered every permission on the form" do
        get edit_repository_member_path(repository, membership)

        expect(response).to have_http_status(:ok)
        RepositoryMembership::PERMISSIONS.each { |permission| expect(response.body).to include(permission) }
        # Pre-ticked from the stored row, so the owner edits what is there rather than starting from
        # a blank grid and re-granting by hand. The negative half matters as much: a grid rendering
        # every box checked would pass the line above.
        expect(response.body).to match(/value="keys\.manage"[^>]*checked/)
        expect(response.body).not_to match(/value="repo\.delete"[^>]*checked/)
      end

      # The OTHER half of anti-trap 1, and it has to be asserted on the markup rather than on a
      # round trip. `edit_member` prepends the blank itself, because that is what a browser sends —
      # which means every example above stays green even with the hidden field deleted from the
      # form. Verified by deleting it: the whole file still passed. A request spec constructs params
      # directly, so it can never observe the browser's "omit unchecked boxes entirely" behaviour;
      # only the rendered form can say whether the blank will be there to omit around.
      #
      # Without it, an owner clearing every box sends no `permissions` key at all and
      # `params.expect` raises ParameterMissing → 400 — so the narrowing this whole slice exists for
      # is the one operation that breaks, and it breaks on the form, not on the server.
      it "renders the hidden blank that makes 'nothing ticked' reach the server as an empty set" do
        get edit_repository_member_path(repository, membership)

        expect(response.body).to match(
          /<input[^>]*type="hidden"[^>]*name="repository_membership\[permissions\]\[\]"[^>]*value=""/
        )
      end

      # The same contract on the add form, which shares the grid partial. Its own examples prepend
      # the blank for the same reason and are blind in the same way.
      it "renders the hidden blank on the add form too" do
        get new_repository_member_path(repository)

        expect(response.body).to match(
          /<input[^>]*type="hidden"[^>]*name="membership_grant\[permissions\]\[\]"[^>]*value=""/
        )
      end

      it "offers the Edit control from the members list" do
        get repository_members_path(repository)

        expect(response.body).to include(edit_repository_member_path(repository, membership))
      end
    end

    # The gate is `:members_manage`, not `:owner` — the roadmap defines that permission as
    # "add/remove collaborators, edit permissions", and re-stamping the grantor on every save is
    # what makes the third clause safe to hand over.
    describe "a member holding 'members.manage'" do
      let!(:own_membership) do
        create_membership(repository: repository, user: colleague, permissions: %w[view members.manage])
      end

      let(:third_party) { create_user(github_uid: "8888", github_handle: "dependabot") }
      let!(:third_party_membership) do
        create_membership(repository: repository, user: third_party, permissions: %w[view])
      end

      # `membership` (hubot's, from the outer let!) is this actor's own row, so it is replaced here.
      let!(:membership) { own_membership }

      # The mock's nickname defaults to the OWNER's, and the callback writes it onto whichever uid
      # signs in — so without this override the callback silently renames the `colleague` row from
      # "hubot" to "octocat", and every example below would run with an actor whose handle is byte-
      # identical to the owner's, contradicting the `let` that declares otherwise. With it the three
      # names in play stay distinct: actor hubot, owner octocat, slug org acme — which is what lets
      # an assertion about who a page NAMES tell the actor and the owner apart.
      before { sign_in_via_github(uid: "9999", info: { nickname: "hubot" }) }

      it "can narrow another member" do
        edit_member(third_party_membership)

        expect(response).to redirect_to(repository_members_path(repository))
        expect(third_party_membership.reload.permissions).to eq([])
      end

      # ⚠ Criterion 3's load-bearing half, and the reason the grantor stamp is not bookkeeping.
      #
      # `third_party_membership` has a NIL grantor, which is the state the model's bound fails OPEN
      # on. An `update` that loaded the row and saved it without re-stamping would leave that row
      # unbounded, and this actor could write `repo.delete` onto it — reopening the exact two-step
      # escalation slice 1d closed, while the model still looks like it is defending against it.
      # repo.delete really does destroy the repository (see repository_sharing_spec), so this is the
      # whole chain, not a permission-string comparison.
      it "cannot grant a permission it does not hold, even on a row that had no grantor" do
        expect(third_party_membership.granted_by_user).to be_nil

        patch repository_member_path(repository, third_party_membership),
              params: { repository_membership: { permissions: ["", "view", "repo.delete"] } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("the grantor does not hold: repo.delete")
        # Refused, not partially applied: the row is exactly as it was.
        expect(third_party_membership.reload.permissions).to eq(%w[view])
        expect(third_party_membership.granted_by_user).to be_nil
      end

      # Criterion 4's first half. The row a member can edit includes their OWN — which is what
      # repository_membership_spec:111 was written for, reaching a controller here for the first
      # time. The bound is measured against what they hold NOW, so a grant cannot bootstrap itself.
      it "cannot escalate its own row" do
        patch repository_member_path(repository, own_membership),
              params: { repository_membership: { permissions: ["", "view", "members.manage", "repo.delete"] } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(own_membership.reload.permissions).to eq(%w[view members.manage])
      end

      # Criterion 4's second half. De-escalating themselves is always within bounds and nothing
      # guards it — but the members page they came from now 403s, because they are still a member
      # and so the repository does not hide from them. `#destroy` already handles the mirror case
      # (revoking yourself redirects to repositories_path); this is the softer half, since the
      # repository itself is still theirs to open.
      it "can edit away its own 'members.manage', and is redirected somewhere it can still reach" do
        edit_member(own_membership, %w[view])

        expect(response).to redirect_to(repository_path(repository))
        expect(own_membership.reload.permissions).to eq(%w[view])

        follow_redirect!
        expect(response).to have_http_status(:ok)

        # The page they would have been sent to is now genuinely refused — 403 rather than 404,
        # since they are still a member. This is the landing the redirect exists to avoid.
        get repository_members_path(repository)
        expect(response).to have_http_status(:forbidden)
      end

      # Criterion 7. The grid renders `grantable_permissions`, so it never offers a box whose save
      # the model would refuse — RepositoryPolicy#grantable_permissions says this is what it is for,
      # and until this slice it had no view or controller call site at all.
      it "is offered only the permissions it can actually grant" do
        get edit_repository_member_path(repository, third_party_membership)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("members.manage")
        expect(response.body).to include("view")
        expect(response.body).not_to include("keys.manage")
        expect(response.body).not_to include("repo.delete")
      end

      # The silent-narrowing disclosure. The grid cannot offer `keys.manage` to this actor, so
      # saving the form drops it — a de-escalation, and safe, but not one they asked for. Silent is
      # the part that is not acceptable on a page whose whole subject is who holds what.
      it "is warned that saving will strip a permission it cannot re-grant" do
        create_membership(repository: repository, user: create_user(github_uid: "5005", github_handle: "ci-bot"),
                          permissions: %w[view keys.manage])
        holder = RepositoryMembership.find_by!(repository: repository, user: User.find_by!(github_handle: "ci-bot"))

        get edit_repository_member_path(repository, holder)

        expect(response.body).to include("Saving will also remove permissions you cannot grant")
        expect(response.body).to include("keys.manage")

        # The warning ends by naming who to ask, and that has to be the owning *account* — this
        # actor's recourse is the person who can re-grant what the save is about to drop. Normalized
        # because the ERB breaks the line between "Ask" and the handle; anchored on the whole
        # sentence so the bare handle in the topbar cannot satisfy it.
        prose = response.body.gsub(/\s+/, " ")
        expect(prose).to include("Ask octocat if that is not what you intend.")
        expect(prose).not_to include("Ask acme")
      end
    end

    # Criterion 6. The whole surface is refused, not just the button — the same discipline the
    # members page itself follows.
    describe "a member with only 'view'" do
      before { sign_in_via_github(uid: "9999") }

      let!(:membership) { create_membership(repository: repository, user: colleague, permissions: %w[view]) }

      it "gets 403 on the form and the save, and changes nothing" do
        get edit_repository_member_path(repository, membership)
        expect(response).to have_http_status(:forbidden)

        edit_member(membership, %w[view repo.delete])
        expect(response).to have_http_status(:forbidden)
        expect(membership.reload.permissions).to eq(%w[view])
      end

      # They cannot open the members page at all, so the affordance question is asked where they can
      # see something: a member who holds `members.manage` sees Edit, and this one never reaches the
      # page that renders it. Asserted as the 403 above plus the absence here, because "no Edit
      # affordance" on a page that returns 403 would otherwise pass vacuously.
      it "is never rendered an Edit control, because the page itself is refused" do
        get repository_members_path(repository)

        expect(response).to have_http_status(:forbidden)
        expect(response.body).not_to include(edit_repository_member_path(repository, membership))
      end
    end

    # 404 rather than 403: the repository's existence stays hidden from a non-member.
    describe "a signed-in user with no membership" do
      before { sign_in_via_github(uid: "7777") }

      it "gets 404 on the form and the save, and changes nothing" do
        get edit_repository_member_path(repository, membership)
        expect(response).to have_http_status(:not_found)

        edit_member(membership, %w[view repo.delete])
        expect(response).to have_http_status(:not_found)
        expect(membership.reload.permissions).to eq(%w[view keys.manage])
      end
    end

    describe "a signed-out visitor" do
      it "is sent to sign in rather than shown the form" do
        get edit_repository_member_path(repository, membership)

        expect(response).to redirect_to(root_path)
      end
    end

    # The same IDOR the revoke path is pinned against, on the two new doors. On this nested route
    # `params[:id]` is a *membership* id while `current_repository` authorized against
    # `params[:repository_id]`, so a global `RepositoryMembership.find` would authorize against
    # repository A and then rewrite a row belonging to repository B — a cross-tenant WRITE, which is
    # strictly worse than the cross-tenant delete, since it can also *grant*.
    describe "editing across repositories" do
      it "refuses a membership id that belongs to a different repository" do
        other_owner = create_user(github_uid: "2002", github_handle: "other-owner")
        other_repository = create_repository(user: other_owner, github_full_name: "acme/payments-service")
        victim = create_membership(repository: other_repository,
                                   user: create_user(github_uid: "3003", github_handle: "victim"),
                                   permissions: %w[view])

        create_membership(repository: repository, user: create_user(github_uid: "9998", github_handle: "admin"),
                          permissions: %w[view members.manage])
        sign_in_via_github(uid: "9998")

        get edit_repository_member_path(repository, victim)
        expect(response).to have_http_status(:not_found)

        patch repository_member_path(repository, victim),
              params: { repository_membership: { permissions: ["", "view", "members.manage"] } }

        expect(response).to have_http_status(:not_found)
        expect(victim.reload.permissions).to eq(%w[view])
      end
    end
  end

  # The sentence printed under each checkbox on both member forms (MembershipsHelper::
  # PERMISSION_DESCRIPTIONS via `_permission_fields`) — the only prose SpecGuard shows explaining
  # what ticking a box hands over, and it is read at the moment of the decision rather than looked
  # up afterwards.
  #
  # It had no example of any kind until this one, and had already drifted: the `members.manage`
  # caption named the revoke door alone, while this same file demonstrates that the identical tick
  # also opens the members page, the add form and the edit form. Under-describing the box that
  # decides who else can reach a private repository means the owner consents to less than they
  # grant, and nothing failed when the add and edit doors moved onto that permission.
  #
  # ⚠ Two things make this example non-vacuous, and both are deliberate:
  #
  #   1. It reads the caption off the RENDERED page, not off the constant. Asserting that every
  #      permission *has* a caption would be green forever — `permission_description` is a `fetch`
  #      over a frozen constant, so presence is structural and could not have caught this.
  #   2. Every clause it demands of the sentence is paired with the request that proves the clause.
  #      So the caption cannot lose a door without failing, and a door cannot close (or open) on
  #      this permission without failing either — which is the direction the original drift ran.
  describe "the caption printed under each permission checkbox" do
    # The caption as the owner reads it: the sentence inside the label that wraps this permission's
    # checkbox. Read off the parsed page rather than matched against the whole body, so these
    # assertions are about the prose under THIS box and not about words that happen to appear
    # somewhere else on the form — including the permission string the same label prints above it.
    def rendered_caption(permission)
      label = css_select("label").find { |node| node.at_css("input[value='#{permission}']") }
      raise "no checkbox rendered for #{permission}" if label.nil?

      # The grid nests the name span and the caption span inside one wrapper; the caption is last.
      label.css("span").last.text.strip
    end

    let(:third_party) { create_user(github_uid: "8888", github_handle: "dependabot") }

    describe "'members.manage', read by an actor who holds it" do
      before do
        create_membership(repository: repository, user: colleague, permissions: %w[view members.manage])
        third_party
        # Nickname pinned for the same reason as the edit block above: the OmniAuth mock defaults it
        # to the owner's, and the callback would rename this actor's row to "octocat".
        sign_in_via_github(uid: "9999", info: { nickname: "hubot" })
      end

      it "names every door the tick opens, and each door named really opens" do
        get new_repository_member_path(repository)
        expect(response).to have_http_status(:ok)
        caption = rendered_caption("members.manage")

        # Nothing below quotes the retired sentence: the clause set retires it on its own (it named
        # neither the add door nor the edit door), and writing it out here would put the string this
        # slice deleted straight back into the repository for the next `git grep` to find.

        # Door 1 — add somebody who was not there.
        expect {
          post repository_members_path(repository),
               params: { membership_grant: { handle: "dependabot", permissions: ["", "view"] } }
        }.to change(RepositoryMembership, :count).by(1)
        expect(caption).to match(/\badds?\b/i)

        # Door 2 — see who has access. Asserted on `dependabot`, who is neither the viewer nor the
        # owner, so the signed-in handle in the topbar cannot satisfy it.
        get repository_members_path(repository)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("dependabot")
        expect(caption).to match(/\bsee\b/i)

        # Door 3 — change what an existing member holds. Widening as well as narrowing, within this
        # actor's own bound: "narrow" alone would be the same under-description in a new place.
        added = RepositoryMembership.find_by!(repository: repository, user: third_party)
        patch repository_member_path(repository, added),
              params: { repository_membership: { permissions: ["", "view", "members.manage"] } }
        expect(added.reload.permissions).to eq(%w[view members.manage])
        expect(caption).to match(/\bchanges?\b/i)

        # Door 4 — take access away again.
        expect {
          delete repository_member_path(repository, added)
        }.to change(RepositoryMembership, :count).by(-1)
        expect(caption).to match(/\bremoves?\b|\brevokes?\b/i)
      end

      # Anti-trap, pinned rather than left to review: both forms assert their rendered body does not
      # contain a permission this viewer may not grant, so a caption that quoted a sibling
      # permission string would break four green examples elsewhere in this file. Asserted here too
      # because THIS is the file a future caption edit is read against.
      it "describes the capabilities without quoting a sibling permission string" do
        get new_repository_member_path(repository)
        caption = rendered_caption("members.manage")

        # Separately, not `include(a, b)` — the negation of a two-argument `include` passes when
        # only one of them is present, which is exactly the half-failure worth catching.
        expect(caption).not_to include("keys.manage")
        expect(caption).not_to include("repo.delete")
      end
    end

    # The owner is the only viewer offered the full grid, so this is where the other three captions
    # are reachable at all. They are accurate today; this pins that they are all still printed, so
    # deleting one is a failure rather than a blank line under a checkbox.
    it "prints a caption under every box the owner is offered" do
      repository
      sign_in_via_github

      get new_repository_member_path(repository)

      RepositoryMembership::PERMISSIONS.each do |permission|
        expect(rendered_caption(permission)).to match(/\A\S.*\.\z/m), "#{permission} has no caption"
      end
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
