# frozen_string_literal: true

# One CI run's metadata. Append-only history: the aggregate counts live here, while the current
# state of each test location lives in SpecIntent.
class TestRun < ApplicationRecord
  belongs_to :repository
  has_many :spec_intents, dependent: :nullify

  validates :commit_sha, presence: true

  def annotated_ratio
    return 0.0 if total_specs_count.to_i.zero?

    (annotated_specs_count.to_f / total_specs_count * 100).round(1)
  end
end
