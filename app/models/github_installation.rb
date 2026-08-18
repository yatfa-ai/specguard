# frozen_string_literal: true

# A GitHub App installation this user reached SpecGuard through — the record that there is something
# for them to read, and where.
#
# It is NOT by itself permission to register what is in it. Only an administrator can install an App
# on a repository, but any member of an organization can later SEE that organization's installation,
# so a row here says a repository was handed to SpecGuard by somebody and says nothing about the
# person holding the row. What this user may actually register is decided by reading the
# installation with that user's OWN credential and requiring `permissions.admin` — see
# `InstallationRepositories`.
#
# `installation_id` is GitHub's public numeric identifier for the installation and is the only thing
# stored. It is not a credential and cannot be used as one: reading anything takes the user's own
# short-lived token, which lives in their session and never here. There is deliberately no token
# column, and so nothing to encrypt and nothing a database dump could leak.
#
# ## Recorded at the callback, not synced
#
# A row is written when GitHub hands the user back from the installation or authorization flow
# (`GithubInstallationsController#callback`). Nothing keeps it in step with GitHub afterwards —
# reacting to installation and uninstall events is a later slice — so the connected set is read
# LIVE from GitHub on every use rather than trusted from here. A row for an installation that has
# since been uninstalled, or that this user has lost access to, costs a `GithubApi::NotFound` on the
# next read and nothing worse, which is exactly the failure a stale row should have.
class GithubInstallation < ApplicationRecord
  belongs_to :user

  # Scoped to the user, not global: two members of the same organization legitimately reach the same
  # installation, and each holds their own row for it. See the migration.
  validates :installation_id, presence: true, uniqueness: { scope: :user_id },
                              numericality: { only_integer: true, greater_than: 0 }

  # Newest first: the account a user connected most recently is the one they are most likely to be
  # thinking about, and it is the order the connected-accounts list reads in.
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  # Record an installation for a user, or refresh the one already there.
  #
  # Idempotent because the callback is: GitHub sends a user here every time they pass through the
  # installation or authorization flow, including when they merely reconfigure which repositories
  # are selected, and a second visit must update the row rather than fail on the uniqueness index or
  # grow a duplicate.
  #
  # Idempotent under CONCURRENCY too, which the validation alone cannot deliver: `find_or_initialize`
  # and `save!` are two statements, so two callbacks racing — a double-click on GitHub's redirect, a
  # browser retry — can both find nothing and both insert. The uniqueness index catches the loser and
  # raises `RecordNotUnique`, which is not a `GithubApi::Error` and would escape the controller's
  # rescue as a 500 on the one flow whose whole selling point is that repeating it is safe. So the
  # loss of that race is treated as what it is: the row exists, which is all the caller wanted. Retried
  # once rather than in a loop, because the only thing that can have changed is the row's existence
  # and the second attempt finds it. `BulkRegistration#save` models the same handling for the same
  # reason.
  #
  # Returns nil for an unusable id rather than raising. The value arrives as a query parameter on a
  # URL a person can edit, so "not a positive integer" is an ordinary thing to receive, and the
  # controller renders a sentence for it.
  def self.record(user:, installation_id:, account_login: nil)
    id = installation_id.to_s.strip.to_i
    return nil unless id.positive?

    attempts = 0
    begin
      write(user: user, installation_id: id, account_login: account_login)
    rescue ActiveRecord::RecordNotUnique
      raise if (attempts += 1) > 1

      retry
    end
  end

  def self.write(user:, installation_id:, account_login:)
    installation = user.github_installations.find_or_initialize_by(installation_id: installation_id)
    # Never overwrite a known login with a nil — a callback that arrives without one says nothing
    # about the account, and blanking the display name is strictly worse than keeping the old one.
    installation.account_login = account_login if account_login.present?
    installation.save!
    installation
  end
  private_class_method :write

  # What to call this installation on screen. Falls back to the id because a row recorded from a
  # callback that carried no login must still be nameable in a list of connected accounts.
  def display_name = account_login.presence || "Installation #{installation_id}"
end
