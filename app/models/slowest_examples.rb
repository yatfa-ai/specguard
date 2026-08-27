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
# It stores no figure of its own: `rows` is `SpecObservation.slowest_in`, and every count is
# `SpecObservation.coverage_in` — one aggregate over the same run's slice.
#
# == Duration is not the only thing a ranked row has to say
#
# `#slowest_in` does not filter on outcome, and it must not: a failed example that ran for sixty
# seconds before blowing up carries a real `run_time` and belongs at the head of a list of what the
# suite spent its time on. What it must not do is arrive there indistinguishable from the run's
# most expensive PASSING test. So the outcome composition of the run travels with the ranking, in
# the same round trip, for the same reason the timing coverage does — and `SpecObservation#outcome_label`
# words the individual row.
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
    new(rows: SpecObservation.slowest_in(test_run, limit: limit).to_a,
        **SpecObservation.coverage_in(test_run))
  end

  # Keywords rather than a positional tuple, and named to match `SpecObservation::COVERAGE_COUNTS`
  # so `.for` can splat one into the other. Six integers in a row is exactly the signature two of
  # them get silently swapped in.
  #
  # EVERY key of that constant is accepted, including ones this panel does not render:
  # `.for` splats the whole hash, so a counter added there and not accepted here is an
  # `ArgumentError` on the dashboard and on `api/v1/repositories#latest_run` — the two callers —
  # rather than a missing figure. `identified_count` is such a key today: it is served on the
  # ingest `202`, where a producer can still act on it, and this panel has no per-example identity
  # sentence to say. It is held rather than dropped so the splat keeps working and the figure is in
  # hand if a surface ever needs it.
  def initialize(rows:, recorded_count:, timed_count:, reported_outcome_count:, identified_count:,
                 failed_count:, pending_count:)
    @rows = rows
    @recorded_count = recorded_count
    @timed_count = timed_count
    @reported_outcome_count = reported_outcome_count
    @identified_count = identified_count
    @failed_count = failed_count
    @pending_count = pending_count
  end

  # The ranking, slowest first. Never longer than the limit it was built with, and shorter whenever
  # the run recorded fewer timed examples than that.
  attr_reader :rows

  # How many rows this run wrote to `spec_observations`, and how many of them carried a duration.
  attr_reader :recorded_count, :timed_count

  # How many of those rows reported an outcome AT ALL, and how many of them named each of the two
  # outcomes counted by name. See `SpecObservation::COVERAGE_COUNTS` for why there is no `passed`
  # figure here and why there must not be one.
  attr_reader :reported_outcome_count, :failed_count, :pending_count

  # How many of this run's rows carried an `example_id` — the upsert key, and the axis the ingest
  # `202` reports as `identified_specs` beside `recorded_specs`. Exposed rather than left as a
  # write-only ivar: this panel says nothing about per-example identity today, and a figure held
  # by the constructor with no way to read it is one nothing could ever start saying. Its
  # shortfall is `recorded_count - identified_count`, never against `TestRun#total_specs_count` —
  # the two are different grains, per the note at the top of this class.
  attr_reader :identified_count

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

  # Whether ANY row of this run said how its example ended — the outcome axis' equivalent of
  # `#recorded?`, and the predicate that keeps this panel off Vacuous Green.
  #
  # `outcome` is nullable and nothing validates it, so a whole run of nils is an ordinary state.
  # On such a run `failed_count` is zero — and a surface that printed "0 failed" over it would be
  # rendering "nothing to check" in the words of "everything passed". The zero is real; what it
  # counts is not failures but silence, and only this predicate can tell the reader which they are
  # looking at. Same separation `#recorded?` draws between "no rows" and "no timings".
  def outcomes_reported? = reported_outcome_count.positive?

  # Rows that reported an outcome that is neither `failed` nor `pending`.
  #
  # Derived by subtraction rather than counted, and NOT called `passed_count`, because nothing
  # platform-side validates the string this counts the absence of two names in. Practically this is
  # the passing examples; formally it is "reported something, and it was neither of the two things
  # SpecGuard reads", and the surface says the second because that is what was measured.
  def other_outcome_count = reported_outcome_count - failed_count - pending_count

  # Rows that reported nothing about how their example ended.
  def unreported_outcome_count = recorded_count - reported_outcome_count
end
