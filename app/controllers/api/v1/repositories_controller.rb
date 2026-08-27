# frozen_string_literal: true

# The agent-readable half of the repository page: which repository a key resolves to, what the
# suite looked like the last time CI reported, and the bounded tail of what it looked like before
# that. Without the `latest_run` block below an agent can learn the suite's size only by running
# the suite and POSTing it — it cannot ask; and without `history` it can learn how the suite GREW
# only by polling this endpoint and subtracting one poll from the next, which is precisely the
# subtraction `TestRun` spends eighteen lines of its own documentation forbidding.
#
# Every figure is read off the same rows `repositories#show` renders from
# (`Repository#latest_test_run` and `#recent_test_runs`, which share an ordering tie-break
# included), so the API and the dashboard cannot name different commits for the same repository.
class Api::V1::RepositoriesController < Api::BaseController
  # THIS ENDPOINT NEEDS A REPOSITORY, and says so rather than discovering it. Every figure this
  # controller serves is read off `current_repository`, so a credential that resolves no repository
  # has nothing to be served here — a `sgu_` user key gets 401. See `Api::BaseController`.
  accepts_repository_credential

  # ⭐ THE TWO BOUNDS STILL ANSWER HERE, and they are ALIASES rather than a second definition —
  # `RepositoryOverview` owns them now, because it owns the `history` block they bound.
  #
  # They are kept at this address because it is a PUBLISHED one: the existing per-block request
  # specs assert against `Api::V1::RepositoriesController::HISTORY_LIMIT` and
  # `::SINGLE_BRANCH_HISTORY_LIMIT` to state the endpoint's cost claim, and those specs are the
  # regression net proving this extraction changed no response. A net that has to be edited to pass
  # is not a net — so the constants moved and the names did not.
  #
  # Assignment, never a restatement of the literals: one source of truth, and the alias cannot drift
  # from the bound the presenter actually applies.
  HISTORY_LIMIT = RepositoryOverview::HISTORY_LIMIT
  SINGLE_BRANCH_HISTORY_LIMIT = RepositoryOverview::SINGLE_BRANCH_HISTORY_LIMIT

  # The overview is ASSEMBLED ELSEWHERE, by `RepositoryOverview`, which is handed a repository and
  # the ask. This controller keeps exactly what is credential-shaped: the repository comes from the
  # `sgk_` key rather than from a path segment, and the `api_key` block below describes that key.
  #
  # `GET /api/v1/repositories/:id` renders the same object for a person holding an `sgu_` key, which
  # is the whole reason the assembly moved — see the class comment there. Nothing about this
  # response changed when it did.
  def show
    render json: RepositoryOverview.new(repository: current_repository, params: params)
                                   .body(api_key_block: serialized_api_key)
  end

  private

  # THE CREDENTIAL THAT MADE THIS REQUEST — the one block of this endpoint that is not
  # repository-scoped, and therefore the one block that does NOT travel to the user-key route,
  # where the caller holds no repository key at all. It is absent there rather than nulled.
  def serialized_api_key
    {
      name: current_api_key.name,
      # ⚠️ THIS ANSWERS "DID ANYTHING AUTHENTICATE", AND THAT IS THE ONLY QUESTION IT CAN ANSWER.
      # It must not be read as evidence that anything was ACCEPTED.
      #
      # `Api::BaseController#authenticate_api_key!` stamps this column on the way IN, before
      # `Api::V1::IngestsController` has looked at the payload — so a delivery refused for its
      # body moves it exactly as far as a delivery that ingested cleanly. A repository whose every
      # run is being thrown away therefore serves a `last_used_at` of "two minutes ago" beside a
      # `latest_run` that is days old, and the freshest figure in the body is the one affirmatively
      # contradicting the staleness of every other one. `repositories#show` served the same
      # contradiction as a `Connected` stat until SPGD-563 corrected it; this is the same
      # correction at the agent surface.
      #
      # `acceptance_reported_by` names the key that answers what this one cannot, rather than
      # leaving a client to discover the distinction by being misled by it once.
      last_used_at: current_api_key.last_used_at&.iso8601,
      acceptance_reported_by: "delivery_health",
      # WHEN THIS KEY WAS LAST REGENERATED, or `null` if it never has been. `regenerate!` retires
      # the previous token with no grace window and deliberately leaves `last_used_at` standing
      # (it is the key's history), so a rotation is the one event that can make the timestamp
      # above describe a credential that no longer exists.
      #
      # ⚠️ IT CANNOT TELL YOU THAT *THIS* KEY IS THE UNUSED ONE, and no field on this block could.
      # `Api::BaseController#authenticate_api_key!` stamps `last_used_at` on the way in, so by the
      # time this body is built the key that requested it has authenticated BY DEFINITION —
      # "rotated and not used since" is false for the requester on every response this endpoint
      # will ever serve. A field for it here would be a constant dressed as a finding.
      #
      # The state is real and it is REPOSITORY-scoped: it is a sibling key, holding a token some
      # other pipeline has not picked up, that a client reaching this endpoint can still learn
      # about — because reaching it at all proves the client's own key works.
      # `credential_health` answers it, on the same convention `acceptance_reported_by` follows
      # above: name the key that answers what this one cannot, rather than leaving a client to
      # discover the distinction by being misled by it once.
      rotated_at: current_api_key.rotated_at&.iso8601,
      rotation_reported_by: "credential_health"
    }
  end
end
