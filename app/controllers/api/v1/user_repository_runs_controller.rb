# frozen_string_literal: true

# DELETING ONE RUN OVER THE API (SPGD-2014) — the machine-facing half of the web surface's
# `resources :runs, only: %i[destroy]` (SPGD-812), one action long, modelled on the two API
# controllers this namespace already has: `Api::V1::UserRepositoriesController#destroy` for the
# gate and the response shape, `Api::V1::UserRepositoryApiKeysController#destroy` for the scoped
# lookup and its 404 wording.
#
# ## Why this is not an action on `RunsController`
#
# That class is an `ApplicationController`: it authenticates a SESSION, composes a human notice
# through a view helper, and redirects through a path helper carrying the web page's window asks
# (`?runs=`, `?runs_branch=`, `?run=`, `?compare_to=` — see its own header for the full list).
# None of that exists on a token-authenticated JSON request, and none of it should: a machine
# caller has no page to land back on. The two share everything that is a RULE rather than a
# rendering — the `:repo_delete` capability gate (one rule, one place, `RepositoryAuthorization`),
# the repository-scoped lookup that makes a foreign run id answer 404, the `destroy!` that fires
# `TestRun`'s `dependent:` cascade, and the census refresh below — so a change to who may delete
# cannot land on one surface and miss the other.
#
# ## The handle is the run's id, and the id comes from the overview body
#
# `latest_run.id` and every `history[]` row's `id` (SPGD-2014, same slice) name runs by their
# primary key — the same number `POST /ingest` answers as `test_run_id` and the console's
# `?run=` anchors on. A commit_sha is deliberately NOT accepted here: one sha can name several
# runs of one repository (re-runs, sharded slices), so a sha-named delete would have to invent a
# "which one" rule, and inventing one is what this API refuses to do — see the web action's own
# reasoning for carrying an id ask.
#
# ## The cascade and the census refresh are the model's and the web action's, mirrored
#
# `test_run.destroy!` fires `TestRun`'s own `dependent:` declarations — shards and observations
# deleted in FK order, durable intents and last-seen identities nullified — which is exactly what
# the web action fires and what its request spec pins. `NearDuplicateCensus.request_refresh!`
# then runs for the same reason it runs there (SPGD-1474): deleting a run can move
# `repository.latest_test_run`, the run every stored census weight is weighed on, and destroys
# the observations those weights join through, so the delete requests the recompute exactly as
# the ingest path does. It lives HERE rather than on a `TestRun` callback for the reason
# `RunsController#destroy` states in full: a repository destroy destroys its runs too, and a
# callback would fire mid-destroy against the `dependent: :destroy` already taking the repository
# away.
#
# `204` with no body, like every DELETE in this API's vocabulary (`UserRepositoriesController`
# states the rule): the resource the URL named no longer exists, so there is nothing to describe.
class Api::V1::UserRepositoryRunsController < Api::BaseController
  # WHO MAY DELETE: a person over their `sgu_` key, or an `sga_` agent credential holding
  # `repo.delete` on a repository in its own set — the same `current_repository(:repo_delete)`
  # gate the repository-delete verb has always answered, so the key's own permission set is the
  # boundary either way. A repository's own `sgk_` key speaks for the repository and gets 401
  # here — see `Api::BaseController`.
  accepts_user_credential
  accepts_agent_credential

  # `find_by` rather than `find`, on `UserRepositoryApiKeysController#destroy`'s rule: a
  # `RecordNotFound` raised by the FIND is this API's own JSON via `Api::BaseController`'s
  # rescue, and so is the one raised HERE — the explicit raise exists only to word it. The wording
  # is the sibling pair's sentence with the noun swapped, because the two refusals mean the same
  # thing about a different row: the id is well-formed but belongs to no run of THIS repository,
  # which covers both a run of another repository and an id matching nothing at all. One 404 for
  # both — telling them apart would confirm, to a caller who should not know, that a foreign id
  # exists somewhere.
  #
  # The `destroy!` and the refresh mirror `RunsController#destroy` in order — row first, then the
  # census marker and its job, then the response — and the comment there carries the full argument
  # for the ordering: a refresh computed before the destroy settled would store a census no live
  # computation would return.
  def destroy
    repository = current_repository(:repo_delete)

    test_run = repository.test_runs.find_by(id: params[:id])
    if test_run.nil?
      raise ActiveRecord::RecordNotFound,
            "No run with that id belongs to this repository."
    end

    test_run.destroy!

    NearDuplicateCensus.request_refresh!(repository.id)

    head :no_content
  end
end
