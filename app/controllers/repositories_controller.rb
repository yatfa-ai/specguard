# frozen_string_literal: true

class RepositoriesController < ApplicationController
  before_action :require_authentication

  def index
    @repositories = current_user.repositories.order(:github_full_name)
  end

  def show
    @repository = current_repository
    @api_keys = @repository.api_keys.order(created_at: :desc)
    # The only signal that the repo ever reached the API: the newest use across every key.
    # `nil` means no key has ever authenticated — see the "Connect this repository" panel.
    @last_api_request_at = @repository.api_keys.maximum(:last_used_at)
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

  def edit
    @repository = current_repository
  end

  # Renaming is a pure metadata change: api_keys, test_runs and spec_intents are keyed by
  # repository_id, so none of them are touched. That is the whole point — the alternative
  # (Remove + re-register) destroys every key and all telemetry.
  def update
    @repository = current_repository

    if @repository.update(repository_params)
      redirect_to repository_path(@repository), notice: rename_notice
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    repository = current_repository
    repository.destroy!

    redirect_to repositories_path, notice: "Removed #{repository.github_full_name}."
  end

  private

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
