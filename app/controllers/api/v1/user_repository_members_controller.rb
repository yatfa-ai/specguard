# frozen_string_literal: true

# WHO ELSE CAN REACH A REPOSITORY, over a `sgu_` user key (SPGD-875) — the member-management
# half of the `sgu_` surface: list, add by handle, edit permissions, revoke.
#
# ## Why this is not `MembershipsController`
#
# That class is an `ApplicationController`: it renders HTML, reads a session, and redirects with
# a flash. This one renders JSON to a person named by a token. What the two share — deliberately
# and structurally — is everything below the rendering: the authorization
# (`current_repository(:members_manage)` from the `RepositoryAuthorization` concern both bases
# include), the handle resolution (`User.resolve_by_handle`), and every mutation rule, which
# lives on `RepositoryMembership` and is reached, never re-checked, from here. A change to who
# may administer members cannot land on one surface and miss the other because both call the
# same seam.
#
# ## The four verbs, and what each refuses
#
#   - non-member caller -> 404, via `RepositoryAuthorization`'s fork (the repository's existence
#     stays hidden);
#   - member without `members.manage` -> 403 (they can already see it, so 404 would be a lie);
#   - a validation refusal -> `render_bad_request` with the model's own sentences.
#
# ## What is deliberately NOT here
#
# `keys_minted`. The web page gates that disclosure on `keys.manage` (see
# `MembershipsController#keys_minted_by`); this read answers memberships to a `members.manage`
# holder and nothing more — the two permissions are independent, and a viewer who may not know
# how many credentials exist on the repository is told nothing, not told less.
class Api::V1::UserRepositoryMembersController < Api::BaseController
  # THIS ENDPOINT NEEDS A PERSON — or an agent credential bounded by its own grants. A repository's
  # own `sgk_` key speaks for the repository, not for anybody who may administer its members, and
  # gets 401 here — see `Api::BaseController`.
  #
  # The `sga_` agent credential is accepted for the READ (who can reach this repository), bounded
  # twice over by `AgentApiKeyPolicy`: the repository must be in the key's set (else 404) and the
  # key must hold `members.manage` (else 403). The MUTATING verbs act as a person — `#create` and
  # `#update` stamp `granted_by_user` from the authenticated principal, and a machine credential
  # is not one — so they guard themselves below and refuse the agent credential with a 403.
  accepts_user_credential
  accepts_agent_credential

  before_action :require_person_credential, only: %i[create update destroy]

  # THE LIST — the same rows the web members page renders (handle, permissions, who last set
  # them, since when), ordered by handle so the response is stable between calls.
  #
  # `includes(:user, :granted_by_user)` for the same N+1 reason the web `#index` states: every
  # row reads two `users` columns, and an unloaded association would cost a query per row. The
  # LEFT OUTER join on the grantor keeps a NULL-grantor row (an ordinary state — see the
  # membership model's no-backfill note) on the list, rendered as `null` rather than dropped.
  #
  # `keys_minted` is ABSENT, not zero — see the class header.
  def index
    repository = current_repository(:members_manage)
    memberships = repository.repository_memberships
                           .includes(:user, :granted_by_user)
                           .order("users.github_handle")

    render json: { members: memberships.map { |membership| serialize(membership) } }
  end

  # ADDING ONE, BY HANDLE — the second production call site of `User.resolve_by_handle`, and the
  # reason it returns a five-way `Resolution` rather than a `User`: each non-`:found` answer is a
  # different fact about the world and earns its own sentence here, exactly as the web `#create`
  # renders each. `:ambiguous` is refused outright — picking one of several rows sharing a
  # recycled handle would silently grant a private repository to a stranger.
  #
  # Everything past resolution is left to `RepositoryMembership`: adding the owner, re-adding a
  # member, naming a nonexistent permission, and the grantor bound are all validations there, so
  # this attempts the save and surfaces whatever it says.
  #
  # `granted_by_user` is stamped HERE, from the credential, and is deliberately absent from
  # `member_params` — `grantor_holds_every_granted_permission` fails OPEN on nil and trusts the
  # grantor it is handed, so permitting a submitted grantor would let a request name the owner
  # and compute the bound against unlimited rights. The recorded grantor is the authenticated
  # `sgu_` principal, always.
  def create
    repository = current_repository(:members_manage)

    resolution = User.resolve_by_handle(params[:handle])
    return render_bad_request([unresolved_message(resolution)]) unless resolution.found?

    membership = repository.repository_memberships.new(
      user: resolution.user,
      permissions: member_params[:permissions],
      granted_by_user: current_api_user
    )

    return render_bad_request(membership.errors.full_messages) unless membership.save

    render json: { member: serialize(membership.reload) }, status: :created
  end

  # EDITING PERMISSIONS — the narrowing path. The membership is found THROUGH the repository
  # (`find_membership!`), so a membership id from a DIFFERENT repository is a 404 rather than a
  # cross-repository write; a global `RepositoryMembership.find` here would let a
  # `members.manage` holder on one repository rewrite another's membership.
  #
  # `assign_attributes` + re-stamp BEFORE save, never `update(...))` — the web `#update` states
  # the reason in as many words: `grantor_holds_every_granted_permission` is computed at
  # validation time and fails OPEN on nil, so a stamp landing after validation would bound
  # nothing, and a `members.manage` holder could hand themselves `repo.delete` through this door.
  def update
    repository = current_repository(:members_manage)
    membership = find_membership!(repository)

    membership.assign_attributes(member_params)
    membership.granted_by_user = current_api_user

    return render_bad_request(membership.errors.full_messages) unless membership.save

    render json: { member: serialize(membership) }
  end

  # REVOKING ONE — the web `#destroy`'s JSON counterpart, down to the two asymmetries that page
  # documents and a caller here must know from the README rather than from a confirm dialog:
  #
  #   - revoking a membership deliberately leaves that member's minted CI keys authenticating
  #     (see `User has_many :created_api_keys, dependent: :nullify`); the lever for those is the
  #     API keys surface, not this one;
  #   - self-revocation is permitted — it is the caller's own access to give up, and no check
  #     prevents it (the next request to these routes answers 404, not 403: a former member is a
  #     non-member).
  #
  # The owner's membership row can never arrive here: an owner membership is structurally
  # impossible (`RepositoryMembership#user_is_not_the_owner`), so that invariant is the model's,
  # not a guard in this action.
  #
  # 204 rather than a body, matching DELETE everywhere else in this API's vocabulary
  # (`UserRepositoryApiKeysController#destroy`).
  def destroy
    repository = current_repository(:members_manage)

    find_membership!(repository).destroy!

    head :no_content
  end

  private

  # Scoped through `repository.repository_memberships`, exactly as the web `find_membership!` is
  # and for the same reason — this is the only thing standing between the nested route and a
  # cross-repository write. The `RecordNotFound` it raises on a foreign id is caught by
  # `Api::BaseController` and rendered as this API's own JSON 404.
  def find_membership!(repository)
    repository.repository_memberships.find(params[:id])
  end

  # Top-level `{handle:, permissions: []}` rather than a nested block, matching
  # `UserRepositoriesController#create_params`'s stated rule — this is JSON an agent writes by
  # hand, not a Rails form.
  #
  # `permissions` is the ARRAY form because the column is `text[]`: a scalar permit silently
  # DROPS the submitted array and persists a member who can open the repository and holds
  # nothing else, without raising — the exact silent-misconfiguration the web `#grant_params`
  # documents and its request spec pins by asserting the STORED array.
  #
  # `handle` is read directly from `params` in `#create` rather than here because it is an
  # input to resolution, not an attribute of the membership: it never reaches the model, so
  # permitting it as though it could be written would misdescribe the request.
  #
  # `granted_by_user_id` is deliberately absent — see `#create`.
  def member_params
    params.permit(permissions: [])
  end

  # One sentence per non-`:found` resolution status — the API's own phrasing of the same five-way
  # fork the web `#unresolved_message` renders, each answer distinguishable because each sends a
  # caller to fix an entirely different thing.
  #
  # `else raise` on purpose, matching the web twin and `RepositoryPolicy#can?`: a sixth status
  # added to `Resolution` must fail on the first request rather than fall through to a default
  # that quietly accepts it.
  def unresolved_message(resolution)
    handle = params[:handle].to_s.strip

    case resolution.status
    when :not_found
      "Nobody has signed into SpecGuard as #{handle} yet — ask them to sign in once, then add them."
    when :archived
      "The SpecGuard account for #{handle} has been archived, so they cannot be given access. " \
        "Archiving is deliberate — their account has to be restored before they can be added."
    when :ambiguous
      "#{resolution.match_count} accounts share the handle #{handle}, so SpecGuard will not guess " \
        "which one you mean. Ask them to sign in again so their handle is current, then try again."
    when :malformed
      "That is not a GitHub handle. Send the login itself — octocat, not a profile URL or a display name."
    else
      raise ArgumentError, "unhandled handle resolution #{resolution.status.inspect}"
    end
  end

  # `keys_minted` is a `keys.manage` disclosure this `members.manage` read does not carry (see
  # the class header). The membership `id` IS served: the API caller has no other way to learn
  # it — no response in this API returns the id PATCH and DELETE name rows by, so withholding it
  # would leave a caller who just added a member unable to edit or revoke what they created.
  # Portability between repositories is refused by `find_membership!`, not by omission here: a
  # foreign repository's id is scoped out before any body could matter, so serving the id inside
  # an already-authorized response discards no guarantee that scoped lookup does not enforce.
  def serialize(membership)
    {
      id: membership.id,
      handle: membership.user.github_handle,
      permissions: membership.permissions,
      granted_by: membership.granted_by_user&.github_handle,
      created_at: membership.created_at.iso8601
    }
  end
end
