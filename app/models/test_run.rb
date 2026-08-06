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

  # The same share as a 0–1 fraction, which is the unit the `/ingest` API reports
  # (see the SpecGuard API Reference). `annotated_ratio` above is the percentage the dashboard renders.
  # Two names rather than one number and a convention: the 100× gap between them is invisible in
  # a JSON body, and a client that guesses wrong is wrong by two orders of magnitude.
  def annotated_fraction
    return 0.0 if total_specs_count.to_i.zero?

    (annotated_specs_count.to_f / total_specs_count).round(3)
  end
end
