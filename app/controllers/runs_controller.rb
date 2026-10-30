# frozen_string_literal: true

# Deleting one run from the "Recent runs" panel (SPGD-812) — the whole controller is this one
# action, modelled directly on `ApiKeysController#destroy`.
#
# Why this exists at all: until now the only way to remove a run was to destroy the whole
# repository, and a junk row (a cancelled job's half-sized shard row) became the repository's
# headline `latest_test_run` indefinitely on a quiet repository. The data-model half of the
# feature was already written and argued — `TestRun`'s `dependent:` declarations handle the
# cascade, nullifying intents and identities and deleting observations in the order the FKs
# require — and had zero callers. This is the route, the action and the control that finally
# issue one.
class RunsController < ApplicationController
  include RequestedRunsParam
  include RequestedRunsBranchParam
  include RequestedRunsBeforeParam

  before_action :require_authentication

  def destroy
    repository = current_repository(:repo_delete)
    test_run = repository.test_runs.find(params[:id])

    # Composed BEFORE the row goes away, the discipline `RepositoriesController#destroy` and
    # `MembershipsController#destroy` both follow: reading a destroyed record's columns to word
    # the notice is reading memory that is no longer backed by anything.
    #
    # SPGD-1958: when the row is the repository's newest it is the run every panel anchors on, so
    # the notice also names the run the page reads once it is gone. The successor is read only in
    # that case — deleting any other row issues neither query.
    was_newest = repository.latest_test_run&.id == test_run.id
    successor = was_newest ? repository.latest_test_run_excluding(test_run) : nil
    notice = helpers.delete_run_notice(test_run, successor: successor, was_newest: was_newest)

    test_run.destroy!

    # SPGD-1474 (rework): deleting a run changes the stored census's inputs — it can move
    # `repository.latest_test_run` (the run every weight figure is weighed on) and it destroys the
    # per-example observations the figures join through — so the delete requests the census
    # refresh exactly as the ingest path does: {NearDuplicateCensus.request_refresh!} raises the
    # marker and schedules {Ingest::NearDuplicateCensusJob}, whose compare-and-clear debounces a
    # burst of deletions into one compute over the settled state. Computing before the destroy
    # settled would store a census no live computation would return, which is the one property
    # the serve path may never break — the same after-the-write placement
    # {Ingest::IdentityResolutionJob} argues for its own refresh.
    #
    # This lives on the CONTROLLER rather than a `TestRun` callback on purpose: a repository
    # destroy destroys its runs too, and a callback would fire there — creating a census row for
    # a repository that is mid-destroy, against the `dependent: :destroy` already taking that row
    # away. A junk-run deletion (SPGD-812's own use case) is precisely the state the ingest-path
    # trigger cannot see, and on a quiet repository it would otherwise last indefinitely.
    NearDuplicateCensus.request_refresh!(repository.id)

    # Back to the window the operator was looking at (SPGD-1916): the Delete form in a widened
    # "Recent runs" panel carries the asked `runs`, and dropping it would collapse the panel to
    # its default after every delete. The ask goes through the same guard and clamp the page
    # itself reads, and the target is built from the path helper, never from request input.
    # No ask leaves the path exactly as it was.
    #
    # SPGD-1922: the branch narrowing rides the same round trip, through the same shape of guard
    # (`RequestedRunsBranchParam`) — deleting a row from a panel narrowed to one branch lands back
    # on that same narrowed panel, and a malformed `runs_branch` on the delete is ignored exactly
    # as it is on the page. `.compact` keeps a no-ask redirect free of both parameters' bytes.
    #
    # SPGD-1984: the keyset cursor rides the same round trip, so deleting a row from page two
    # lands back on page two. One exception, the same one the Delete form in the view applies: a
    # deleted row that IS the carried cursor drops it — the redirect would otherwise name a
    # position that no longer exists, and the followed page would fall back to the newest window
    # anyway. The resolution itself stays on the page (`RunsController` does not re-read the run
    # table for the cursor); a well-formed id matching nothing is carried and answered by the
    # default window, exactly as a well-formed unknown branch is.
    redirect_to repository_path(repository, **{
      runs: requested_runs,
      runs_branch: requested_runs_branch,
      runs_before: (requested_runs_before unless requested_runs_before == test_run.id)
    }.compact),
                notice: notice
  end
end
