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

    redirect_to repository_path(repository), notice: notice
  end
end
