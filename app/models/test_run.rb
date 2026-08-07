# frozen_string_literal: true

# One CI run's metadata. Append-only history: the aggregate counts live here, while the current
# state of each test location lives in SpecIntent.
#
# One row is one *run*, which is not the same as one POST: a sharded suite delivers itself over N
# requests and `Ingest::RunRecorder` folds every one of them onto the row named by `ci_run_id`.
# For those rows the counters here are **derived** — the SUM of `test_run_shards`, with
# `duration_seconds` the MAX, recomputed on every ingest — which is what makes a redelivered shard
# replace its own slice rather than add to it. `ci_run_id` is nil for every run no CI provider
# named; those rows have no shards, are written once, and are left exactly as they always were.
class TestRun < ApplicationRecord
  belongs_to :repository
  has_many :spec_intents, dependent: :nullify
  has_many :test_run_shards, dependent: :destroy

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

  # Whether the client reported a wall clock at all. `duration_seconds` is nullable by design and
  # `Ingest::Payload#validate_duration_seconds` accepts nil explicitly, so "no timing was sent" is
  # a real state — and a distinct one from a run that genuinely measured 0.0 seconds. Deliberately
  # `nil?` rather than `present?`: `0.0.present?` is true, but reading the predicate as "is there a
  # number here" and answering it with a blank check is how a measured zero starts rendering as an
  # omission.
  def duration_reported? = !duration_seconds.nil?

  # The run's wall clock, formatted once for every surface that shows it. Both readers of this
  # column — the Overview panel's header figure and the Recent-runs table cell — go through here,
  # so the same float cannot render two ways on one page.
  #
  # Seconds below a minute keep their tenth, which is the precision the Recent-runs cell already
  # rendered this column at. At a minute and above the tenth stops carrying anything a reader
  # wants and `372.4s` stops being legible as "six minutes", so it becomes h/m/s parts instead.
  # A zero part is dropped unless a larger part is present, which keeps `1h 0m 12s` from
  # collapsing into a misleading `1h 12s`.
  def duration_label
    return "not reported" unless duration_reported?

    seconds = duration_seconds.to_f
    return "#{seconds.round(1)}s" if seconds < 60

    hours, remainder = seconds.round.divmod(3600)
    minutes, whole_seconds = remainder.divmod(60)

    parts = []
    parts << "#{hours}h" if hours.positive?
    parts << "#{minutes}m" if minutes.positive? || hours.positive?
    parts << "#{whole_seconds}s" if whole_seconds.positive?
    parts.join(" ")
  end
end
