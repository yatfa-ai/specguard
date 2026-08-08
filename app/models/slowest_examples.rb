# frozen_string_literal: true

# One run's slowest examples, together with the coverage the surface listing them has to state.
#
# == Why the list and its caption are one object
#
# The caption is a claim ABOUT the list — "ranked over the 4,812 of 4,900 examples that carried a
# duration" is only true if the two figures count the same run's rows the ranking scanned. Fetched
# separately into separate ivars, they are two things that agree today and have no structural
# reason to keep agreeing, which is how a caption ends up describing a row set that is no longer
# under it. `SuiteTrajectory` states the same rule for its own captions at the grain above.
#
# It stores no figure of its own: `rows` is `SpecObservation.slowest_in`, and the two counts are
# `SpecObservation.timing_coverage_in` — one aggregate over the same run's slice.
#
# == The denominator is the rows, not the suite size
#
# Deliberately not `TestRun#total_specs_count`. That figure is derived by SUM over
# `test_run_shards` and `SpecObservation`'s class comment is explicit that nothing at this grain
# re-derives it; `Ingest::ObservationRecorder#record` returns a row count that is *"not always
# `specs.size`"*, so the two can legitimately differ. A panel that ranked rows here and reported
# coverage against a counter assembled elsewhere would be dividing one measurement by another
# thing's — and on a half-delivered sharded run, by one still climbing toward its own total.
#
# Two bounded queries for the whole panel, neither growing with the size of the suite: an indexed
# backward scan capped at `SpecObservation::SLOWEST_LIMIT`, and one aggregate over the same index's
# leading column.
class SlowestExamples
  def self.for(test_run, limit: SpecObservation::SLOWEST_LIMIT)
    recorded_count, timed_count = SpecObservation.timing_coverage_in(test_run)

    new(rows: SpecObservation.slowest_in(test_run, limit: limit).to_a,
        recorded_count: recorded_count.to_i,
        timed_count: timed_count.to_i)
  end

  def initialize(rows:, recorded_count:, timed_count:)
    @rows = rows
    @recorded_count = recorded_count
    @timed_count = timed_count
  end

  # The ranking, slowest first. Never longer than the limit it was built with, and shorter whenever
  # the run recorded fewer timed examples than that.
  attr_reader :rows

  # How many rows this run wrote to `spec_observations`, and how many of them carried a duration.
  attr_reader :recorded_count, :timed_count

  # Whether this run recorded per-example rows AT ALL — a different question from whether any of
  # them were timed, and the one that decides whether the surface has anything to say. A run
  # ingested before those rows existed, or one whose client sends no per-example detail, has no
  # per-test grain to disclose; a run that recorded examples and timed none of them does, and it
  # is `#any?` that separates those two.
  def recorded? = recorded_count.positive?

  def any? = rows.any?

  # Every recorded row carried a duration — the state worth SAYING rather than leaving to be
  # inferred from two equal numbers, since "the ranking covers everything this run reported" is the
  # reading a reader would otherwise have to do the subtraction to reach.
  def complete? = recorded? && timed_count == recorded_count

  # Rows the ranking could not consider. Not a defect and not a gap to paper over: an example that
  # never ran has no duration to report, so a nil is a faithful record — see
  # `Ingest::ObservationRecorder#attributes`.
  def untimed_count = recorded_count - timed_count
end
