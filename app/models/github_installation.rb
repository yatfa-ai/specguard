# frozen_string_literal: true

# A GitHub App installation this user reached SpecGuard through — and, because only an
# administrator of a repository can install an App on it, the proof that they may register what is
# in it.
#
# `installation_id` is GitHub's public numeric identifier for the installation and is the only thing
# stored. The credential SpecGuard reads with is minted from it on demand and expires within the
# hour (`GithubAppCredentials`); there is deliberately no token column here, and so nothing to
# encrypt and nothing a database dump could leak.
#
# ## Recorded at the setup URL, not synced
#
# A row is written when GitHub hands the user back from the installation flow
# (`GithubInstallationsController#create`). Nothing keeps it in step with GitHub afterwards —
# reacting to installation and uninstall events is a later slice — so the connected set is read
# LIVE from GitHub on every use rather than trusted from here. A row for an installation that has
# since been uninstalled costs a `GithubApi::NotFound` on the next read and nothing worse, which is
# exactly the failure a stale row should have.
class GithubInstallation < ApplicationRecord
  belongs_to :user

  # Scoped to the user, not global: two administrators of the same organization legitimately reach
  # the same installation, and each holds their own row for it. See the migration.
  validates :installation_id, presence: true, uniqueness: { scope: :user_id },
                              numericality: { only_integer: true, greater_than: 0 }

  # Newest first: the account a user connected most recently is the one they are most likely to be
  # thinking about, and it is the order the connected-accounts list reads in.
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  # Record an installation for a user, or refresh the one already there.
  #
  # Idempotent because the setup URL is: GitHub sends a user here every time they pass through the
  # installation flow, including when they merely reconfigure which repositories are selected, and
  # a second visit must update the row rather than fail on the uniqueness index or grow a duplicate.
  #
  # Returns nil for an unusable id rather than raising. The value arrives as a query parameter on a
  # URL a person can edit, so "not a positive integer" is an ordinary thing to receive, and the
  # controller renders a sentence for it.
  def self.record(user:, installation_id:, account_login: nil)
    id = installation_id.to_s.strip.to_i
    return nil unless id.positive?

    installation = user.github_installations.find_or_initialize_by(installation_id: id)
    # Never overwrite a known login with a nil — a callback that arrives without one says nothing
    # about the account, and blanking the display name is strictly worse than keeping the old one.
    installation.account_login = account_login if account_login.present?
    installation.save!
    installation
  end

  # What to call this installation on screen. Falls back to the id because a row recorded from a
  # callback that carried no login must still be nameable in a list of connected accounts.
  def display_name = account_login.presence || "Installation #{installation_id}"
end
