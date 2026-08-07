# frozen_string_literal: true

class RepositoriesController < ApplicationController
  before_action :require_authentication

  # Both are per-card questions asked by repositories/index, once per repository in the list.
  helper_method :owns_repository?, :key_count_visible?

  # Everything the viewer can open: what they own, plus what has been shared with them. Kept as one
  # relation rather than `owned + shared`, because concatenating two Arrays orders them
  # owned-then-shared and silently loses the alphabetical order the page is sorted by.
  #
  # No `.distinct`: RepositoryMembership rejects a row for the owner outright
  # (`user_is_not_the_owner`), so the two sides cannot overlap. A defensive uniq here would mask
  # that invariant breaking rather than let it fail loudly.
  def index
    @repositories = Repository.where(user_id: current_user.id)
                              .or(Repository.where(id: current_user.repository_memberships.select(:repository_id)))
                              .order(:github_full_name)
  end

  def show
    @repository = current_repository(:view)
    # `includes` because the table names the creator of every row — without it, listing keys is
    # one user query per key.
    @api_keys = @repository.api_keys.includes(:created_by_user).order(created_at: :desc)
    # The only signal that the repo ever reached the API: the newest use across every key.
    # `nil` means no key has ever authenticated — see the "Connect this repository" panel.
    @last_api_request_at = @repository.api_keys.maximum(:last_used_at)
    # Every suite figure on the Overview panel is read off this one row — suite size, annotated
    # count, and the difference between them. `nil` is load-bearing and means *never ingested*,
    # which the panel renders as an empty state rather than as `0%`; a repository whose CI has
    # never reported must not look identical to one that reported and genuinely found no
    # annotations. Deliberately not `Repository#annotated_ratio`, which cannot express that
    # difference (it floors at 0.0 by contract — see spec/models/repository_spec.rb).
    @latest_test_run = @repository.latest_test_run
    # The tail of that same append-only history for the "Recent runs" panel. Bounded at ten rows by
    # the model, so this stays O(1) no matter how long CI has been reporting. It shares
    # `latest_test_run`'s ordering by construction, so the run named on the Overview panel above is
    # always the top row here — the two panels cannot name different commits on the same page.
    @recent_test_runs = @repository.recent_test_runs
    # Set by ApiKeysController#create and readable exactly once — see ApiKeysController.
    @revealed_token = flash[:revealed_api_key]
    @revealed_token_name = flash[:revealed_api_key_name]
  end

  def new
    @repository = current_user.repositories.new
  end

  def create
    @repository = current_user.repositories.new(repository_params)

    if @repository.save
      redirect_to repository_path(@repository), notice: "Registered #{@repository.github_full_name}."
    else
      render :new, status: :unprocessable_content
    end
  end

  # Rename is owner-only. `github_full_name` is both the repository's identity and the globally
  # unique key, so no membership permission grants it — a member with `view` gets 403 here.
  def edit
    @repository = current_repository(:owner)
  end

  # Renaming is a pure metadata change: api_keys, test_runs and spec_intents are keyed by
  # repository_id, so none of them are touched. That is the whole point — the alternative
  # (Remove + re-register) destroys every key and all telemetry.
  def update
    @repository = current_repository(:owner)

    if @repository.update(repository_params)
      redirect_to repository_path(@repository), notice: rename_notice
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    repository = current_repository(:repo_delete)
    repository.destroy!

    redirect_to repositories_path, notice: "Removed #{repository.github_full_name}."
  end

  private

  # `user_id` is already loaded on the record, so this asks nothing of the database.
  def owns_repository?(repository)
    repository.user_id == current_user&.id
  end

  # The index card must not hand a member more key information than repositories#show is willing to
  # give them: that page gates the whole API keys panel — names, hints, last-used — behind
  # `keys.manage`, so a bare count on the card would leak past the same line.
  #
  # Deliberately *not* `repository_policy(repository).can?(:keys_manage)`. That helper memoizes per
  # repository but loads its membership with a `find_by`, so asking it once per card costs one query
  # per shared card. `shared_permissions` below is the same answer in a single query.
  def key_count_visible?(repository)
    return true if owns_repository?(repository)

    Array(shared_permissions[repository.id]).include?(RepositoryMembership::KEYS_MANAGE)
  end

  # `repository_id => permissions` for every membership the viewer holds, loaded in one query and
  # memoized for the request — so the answer above costs the same whether the list has one shared
  # card or fifty.
  def shared_permissions
    @shared_permissions ||= current_user.repository_memberships.pluck(:repository_id, :permissions).to_h
  end

  def repository_params
    params.expect(repository: [:github_full_name])
  end

  # Submitting the form unchanged is a valid save, so don't claim a rename that didn't happen.
  def rename_notice
    if @repository.saved_change_to_github_full_name?
      "Renamed to #{@repository.github_full_name}."
    else
      "#{@repository.github_full_name} is already up to date."
    end
  end
end
