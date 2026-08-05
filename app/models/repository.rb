# frozen_string_literal: true

# A registered GitHub repository — the tenant boundary for everything SpecGuard stores.
# API keys, test runs and spec intents all hang off it.
class Repository < ApplicationRecord
  FULL_NAME_FORMAT = %r{\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z}

  belongs_to :user
  has_many :api_keys, dependent: :destroy
  has_many :test_runs, dependent: :destroy
  has_many :spec_intents, dependent: :destroy

  before_validation :normalize_full_name
  before_validation :derive_name

  validates :github_full_name, presence: true, uniqueness: { case_sensitive: false },
                               format: { with: FULL_NAME_FORMAT, message: "must look like org/repo" }
  validates :name, presence: true

  def owner_login = github_full_name.to_s.split("/").first

  def github_url = "https://github.com/#{github_full_name}"

  # Share of the suite that carries an @intent annotation — the headline dashboard metric.
  def annotated_ratio
    total = spec_intents.count
    return 0.0 if total.zero?

    (spec_intents.where(status: "annotated").count.to_f / total * 100).round(1)
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
