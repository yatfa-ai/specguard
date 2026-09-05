# frozen_string_literal: true

# The person's own page: what belongs to them rather than to any one repository.
#
# Today that is their `sgu_` user API keys, their registration grant, their connected GitHub
# accounts — and closing the account itself (SPGD-853), the writer for `users.archived_at` the
# enforcement points have been policing since SPGD-358. The page is deliberately not named for
# any of its occupants: an account surface is where a profile, a notification setting or a
# sign-out-everywhere control would land, and naming the route after its first occupant would
# make each of those a second top-level page.
class AccountsController < ApplicationController
  before_action :require_authentication

  def show
    # Newest first: the key somebody just minted is the one they came back to check, and the reveal
    # panel above the table is about that same row. Tie-broken by id so two keys minted in the same
    # instant — which a person clicking twice can produce — still order deterministically, the same
    # rule `Repository#latest_test_run` follows.
    @user_api_keys = current_user.user_api_keys.order(created_at: :desc, id: :desc)

    # THE AGENT CREDENTIALS (SPGD-952) — the same ordering rule as the personal keys above, and on
    # the same page because the same person mints both. The panel below the personal-keys panel is
    # where a reader learns what these are: a set of repositories and a set of permissions, fixed
    # at mint time out of this person's rights, carried by a token that speaks for nobody.
    @agent_api_keys = current_user.agent_api_keys.order(created_at: :desc, id: :desc)

    # WHAT THIS PERSON MAY GRANT an agent key access to — the same read-side boundary every
    # surface asking "which repositories may this person see" asks, ordered the way the mint
    # form lists them. A repository missing here is one the person cannot open, and the model's
    # grant validation would refuse it anyway; the form shows only what can honestly be ticked.
    @grantable_repositories = Repository.accessible_by(current_user).order(:github_full_name)

    # WHAT THE MINT FORM MAY OFFER — the union of `RepositoryPolicy#grantable_permissions`
    # across the repositories above (see `grantable_permissions_for` below for the one-read
    # spelling and the rules it restates). The permission grid renders from this and never from
    # `RepositoryMembership::PERMISSIONS` whole: a box no tickable repository would accept is a
    # control whose only possible outcome is the model's refusal on submit — the exact shape
    # `_permission_fields.html.erb` renders its own grids to prevent. The BOUND itself stays
    # per-repository on the model — a permission held on one ticked repository but not another
    # is still refused, by a flash naming both — so this grid promises only what is true of it:
    # it never offers what NO accessible repository accepts.
    @grantable_permissions = grantable_permissions_for(@grantable_repositories)

    # Set by UserApiKeysController#create, readable exactly once. One reveal-once mechanism for
    # both credentials, not two: a second implementation is a second chance to get "shown exactly
    # once" wrong, and the two pages can never be reached by one redirect. The KEY NAMES, however,
    # are this surface's own — `ApiKeysController` writes, and `RepositoriesController#show` reads,
    # a distinct pair — because a flash is delivered to whatever request arrives next, and one
    # shared namespace let an intervening repository page read (and mislabel) this surface's token.
    @revealed_token = flash[:revealed_user_api_key]
    @revealed_token_name = flash[:revealed_user_api_key_name]

    # Set by AgentApiKeysController#create, readable exactly once — this surface's own mailbox
    # pair, the third, on the rule the pair above records: one namespace per credential kind, so
    # no intervening page can read (and mislabel) another surface's reveal.
    @revealed_agent_token = flash[:revealed_agent_api_key]
    @revealed_agent_token_name = flash[:revealed_agent_api_key_name]

    # REGISTRATION ACCESS, which is the one credential on this page that EXPIRES and the only one
    # whose age was reported nowhere. The keys above are revoked or they work; a
    # `GithubRegistrationGrant` lapses after `GithubRegistrationGrant::MAX_AGE` on its own, and
    # nothing looks broken when it does — `GET /api/v1/repositories` needs no grant and keeps
    # answering, and `last_used_at` keeps updating. A person who mints a key, hands it to an agent
    # and does not open SpecGuard in a browser for a week loses the ability to register with no
    # sign of it anywhere. This page is where that had to become visible, beside the credential it
    # is a property of.
    #
    # Through the `has_one` association rather than a `find_by`, matching what
    # `Api::V1::UserRepositoriesController#grant_verifier` reads: "one grant per person" is a fact
    # of the schema (unique index on `user_id`) rather than a convention each caller re-states.
    #
    # `nil` is an ORDINARY state — every person who has not listed repositories in a browser since
    # the grant mechanism shipped — and the view says so rather than treating it as an error.
    #
    # ⚠️ This is a READ. It must never become a `GithubRegistrationGrant.capture`: the sole capture
    # site is `GithubRepositoryListing#github_sources`, deliberately, because that is a GitHub read
    # the browser was making anyway. Refreshing from here would add a page-walk per installation to
    # a page that lists no repositories.
    @registration_grant = current_user.github_registration_grant

    # CONNECTED GITHUB ACCOUNTS — the rows `GithubInstallationsController#callback` writes, which
    # until now appeared on no page at all and could be removed by nothing short of deleting the
    # whole user. `User#github_installations` says the principle outright while justifying its
    # `dependent: :destroy`: connecting GitHub is not the sort of act that should quietly become
    # irreversible. The cascade was the only satisfier funded; this list and its Disconnect are the
    # other half.
    #
    # `recent_first` rather than a fresh `order` here — its own comment already names this list as
    # the reason it exists, so the ordering rule lives with the model instead of being restated at
    # the one call site that could drift from it.
    #
    # ⚠️ A READ, on the same terms as the grant above and for a sharper reason: these rows are not
    # synced with GitHub (see `GithubInstallation`), and the honest way to show what is really there
    # would be a live page-walk per installation. That is the cost `/repositories/new` already pays
    # and this page deliberately does not — listing SpecGuard's own record is what the panel claims
    # to show, and it is what the Disconnect acts on.
    @github_installations = current_user.github_installations.recent_first
  end

  # Closes the signed-in person's own account (SPGD-853) — the first writer `users.archived_at`
  # has ever had. SPGD-358 shipped three enforcement points for this state (sign-in refused,
  # live sessions killed, `sgu_` tokens 401'd) and no way to enter it; this action is that way,
  # and the panel in `accounts/show` is its confirm dialog.
  #
  # ARCHIVING, NOT DELETING, and the distinction is the whole design: `update!` stamps one
  # column and touches nothing else. The `:restrict_with_error` declarations on User hold the
  # destroy path closed — this action is the "archive/disable" answer they were written to wait
  # for — and the refusal copy in SessionsController is where the one-way nature of the state is
  # disclosed, because that is the page a closed person actually reaches.
  #
  # `update!` on `current_user` and no parameter beside it: whose account closes is the session's
  # answer alone (see the route note). `reset_session` afterwards, not before — the write is the
  # act, and the session-ending mirrors `SessionsController#refuse_archived`/`#destroy`: end the
  # session, then send the person to the signed-out root with a message that says what happened.
  # The root page is also where a stray sign-in attempt would land them, so the notice and that
  # refusal alert describe the same state in the same words.
  def close
    current_user.update!(archived_at: Time.current)
    reset_session

    redirect_to root_path,
                notice: "Your account is closed. You have been signed out, and SpecGuard can no " \
                        "longer sign you in. Nothing of yours was deleted."
  end

  private

  # THE UNION THE MINT GRID OFFERS — `RepositoryPolicy#grantable_permissions` for every accessible
  # repository at once, read in ONE pass over `repository_memberships` rather than one query per
  # repository. The per-repository spelling this replaces built a fresh `RepositoryPolicy` per
  # accessible repository, and each instance's memoized `find_by` cost one query — the exact cost
  # `RepositoriesController#key_count_visible?` declines in writing for the same call, with
  # `shared_permissions` there as the settled one-read alternative. The answer is the union's,
  # byte for byte; the three rules the policy owns are RESTATED here rather than inherited, because
  # a hand-rolled union that silently drops any of them would answer a page the policy never would:
  #
  #   * OWNER ⇒ THE WHOLE VOCABULARY. `can?` returns true on `owner?` before consulting any row,
  #     so a person owning any accessible repository may grant all four.
  #   * MEMBERSHIP IMPLIES `view`. A row holding only `keys.manage` — or holding nothing at all —
  #     still contributes `view`, because the membership itself grants it
  #     (`RepositoryPolicy#can?`); this is what keeps the answer honest for a member whose row
  #     omits "view".
  #   * A ROW'S STORED PERMISSIONS CONTRIBUTE THEMSELVES — `repo.delete` included. It is a
  #     storable permission like the other three: `RepositoryPolicy::CAPABILITIES` maps
  #     `:repo_delete` to the stored string and only `:owner` maps to the `OWNER_ONLY` sentinel,
  #     so `can?(:repo_delete)` reads the row. That is why `RepositoriesController#destroy` gates
  #     at `:repo_delete` rather than `:owner` — a member granted it may destroy the owner's
  #     repository — and why the members form offers it to that same member. Subtracting it here
  #     would hide a box the model accepts and the membership grid offers: the inverse of the
  #     over-offer this grid exists to prevent, and just as false to the policy.
  #
  # `Array#&` hands the grid the vocabulary's own order (`PERMISSIONS` on the left) rather than
  # whatever order the rows happened to produce, so the grid does not reshuffle as memberships
  # change. The BOUND itself stays per-repository on the model — this union widens only what the
  # form offers, never what a mint may contain.
  def grantable_permissions_for(repositories)
    repository_ids = repositories.map(&:id)
    return [] if repository_ids.empty?

    # The ownership dominance check reads the LOADED set deliberately: the `map(&:id)` above has
    # already materialized the relation, so this `user_id` scan runs in memory and costs no query.
    # Reordering the two lines — or handing the method a relation nobody has enumerated — turns
    # the scan into a second `repository_memberships` read for nothing.
    return RepositoryMembership::PERMISSIONS.dup if repositories.any? { |r| r.user_id == current_user.id }

    RepositoryMembership::PERMISSIONS &
      current_user.repository_memberships
                  .where(repository_id: repository_ids)
                  .flat_map { |membership|
                    [RepositoryMembership::VIEW] + membership.permissions
                  }
  end
end
