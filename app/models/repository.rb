# frozen_string_literal: true

# A registered GitHub repository — the tenant boundary for everything SpecGuard stores.
# API keys, test runs and spec intents all hang off it.
class Repository < ApplicationRecord
  FULL_NAME_FORMAT = %r{\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z}

  belongs_to :user
  has_many :api_keys, dependent: :destroy
  has_many :test_runs, dependent: :destroy
  has_many :spec_intents, dependent: :destroy
  has_many :repository_memberships, dependent: :destroy
  # Everyone granted access who is *not* the owner. The owner is `user` and holds every permission
  # implicitly, so they never appear here.
  has_many :members, through: :repository_memberships, source: :user

  before_validation :normalize_full_name
  before_validation :derive_name

  validates :github_full_name, presence: true, uniqueness: { case_sensitive: false },
                               format: { with: FULL_NAME_FORMAT, message: "must look like org/repo" }
  validates :name, presence: true

  def owner_login = github_full_name.to_s.split("/").first

  def github_url = "https://github.com/#{github_full_name}"

  # Share of the suite that carries an @intent annotation — the headline dashboard metric.
  #
  # Sourced from the most recent `TestRun`, not from `spec_intents`. Counting rows here could only
  # ever return 100%: `spec_intents.entity/action/behavior/layer` are all NOT NULL, so an
  # unannotated spec — which by definition has none of them — is not a row ingestion can write.
  # Ingestion therefore *counts* unannotated specs into the run's totals and persists only the
  # annotated ones, which makes the run's own counters the honest denominator.
  def annotated_ratio
    latest_test_run&.annotated_ratio || 0.0
  end

  # Ties broken by id so two runs ingested in the same instant still order deterministically.
  def latest_test_run
    test_runs.order(created_at: :desc, id: :desc).first
  end

  # The tail of the append-only run history, newest first — what the "Recent runs" panel lists.
  #
  # Deliberately the *same* ordering as `latest_test_run` above, tie-break included. The two are
  # read side by side on the repository page (Overview names the latest run, this panel's top row
  # names it again), so an ordering that disagreed by even the id tie-break would print two
  # different commits for the same run on the same screen.
  #
  # Bounded by `limit` rather than paginated: this is a history of *runs*, so ten rows is ten rows
  # whether the suite holds three tests or twenty thousand.
  def recent_test_runs(limit: 10)
    test_runs.order(created_at: :desc, id: :desc).limit(limit)
  end

  private

  def normalize_full_name
    self.github_full_name = github_full_name.to_s.strip.delete_prefix("https://github.com/")
                                            .delete_suffix(".git").delete_suffix("/").presence
  end

  def derive_name
    self.name = github_full_name.to_s.split("/").last.presence || name
  end
end
