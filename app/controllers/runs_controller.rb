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
  before_action :require_authentication

  def destroy
    repository = current_repository(:repo_delete)
    test_run = repository.test_runs.find(params[:id])

    # Composed BEFORE the row goes away, the discipline `RepositoriesController#destroy` and
    # `MembershipsController#destroy` both follow: reading a destroyed record's columns to word
    # the notice is reading memory that is no longer backed by anything.
    notice = helpers.delete_run_notice(test_run)

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

    redirect_to repository_path(repository), notice: notice
  end
end
