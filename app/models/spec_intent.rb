# frozen_string_literal: true

# One declared test intent, carrying its embedding. The central object of the schema.
#
# Ownership is `(repository, file_path, line_number)` — enforced by a unique index — not the
# test run. `test_run` only records the run that last observed this intent (audit trail), which
# is why it is optional.
class SpecIntent < ApplicationRecord
  LAYERS = %w[unit integration request system].freeze
  STATUSES = %w[annotated unannotated].freeze

  belongs_to :repository
  belongs_to :test_run, optional: true

  # neighbor: gives us `.nearest_neighbors(:embedding, …)` for the Phase 3 duplicate engine.
  has_neighbors :embedding

  validates :file_path, :entity, :action, :behavior, presence: true
  validates :line_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :layer, inclusion: { in: LAYERS }
  validates :status, inclusion: { in: STATUSES }
  validates :file_path, uniqueness: { scope: [:repository_id, :line_number] }

  scope :annotated, -> { where(status: "annotated") }

  def location = "#{file_path}:#{line_number}"
end
